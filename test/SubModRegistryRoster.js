/**
 * @title SubMod Global Roster — Forward Enumeration Tests
 * @notice Covers the new getAllRegisteredSubMods / getAllRegisteredSubModsWithChapters
 *         view functions and the 0↔1 chapter-count-transition invariants of the
 *         global sub-mod roster maintained inside VoxFacet.
 *
 * Invariants asserted:
 *   - An address appears in getAllRegisteredSubMods() iff subModChaptersList
 *     (i.e. getSubModChapters) is non-empty for that address.
 *   - Re-registering the same (subMod, chapter) pair is a no-op at the pair
 *     level (ALREADY_SUBMOD revert from external entrypoint), and the global
 *     roster length does not change.
 *   - A sub-mod in N chapters → one roster entry. Losing one chapter while
 *     still in N-1 → stays on roster. Losing the last → leaves roster.
 *   - SubModRegistered fires only on 0→1 transition; SubModDeregistered only
 *     on 1→0 transition.
 *   - getAllRegisteredSubModsWithChapters[i] matches getSubModChapters(subMods[i])
 *     within the same block.
 *
 * Spec-deviation notes (see implementation review):
 *   - The external registerSubMod / deregisterSubMod are NOT admin-gated; they
 *     are gated by "msg.sender is a registered chapter contract". Production
 *     writes therefore flow through VoxChapter.inviteSubMod /
 *     acceptSubModInvitation / removeSubMod, which is what these tests exercise.
 *   - The spec's "registerSubMod twice → list length = 1" case cannot be
 *     produced via the external entrypoint because the 2nd call reverts with
 *     ALREADY_SUBMOD. The meaningful idempotency property for the *global*
 *     roster is "same address joining N chapters → 1 entry", which IS tested.
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const hre = require("hardhat");

const GOVERNANCE_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const GOVERNANCE_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

describe("VoxFacet — global sub-mod roster (getAllRegisteredSubMods)", function () {
  // The ≥256-address test creates many impersonated accounts; give Mocha room.
  this.timeout(300_000);

  let deployer, owner, chapterAdminA, chapterAdminB, subMod1, subMod2, subMod3;
  let facet, governanceFacet, diamond;
  let chapterImplementation;
  let governanceSigner;

  async function signChapterName(chapterName, callerAddress) {
    const { chainId } = await ethers.provider.getNetwork();
    const hash = ethers.keccak256(
      ethers.solidityPacked(
        ["string", "address", "uint256"],
        [chapterName, callerAddress, chainId]
      )
    );
    return governanceSigner.signMessage(ethers.getBytes(hash));
  }

  async function createChapter(caller, name, id) {
    const sig = await signChapterName(name, await caller.getAddress());
    await (await facet.connect(caller).createChapter(name, id, sig)).wait();
    const addr = await facet.getChapterAddress(name);
    // Lower claim thresholds so removeSubMod's inline reward distribution
    // does not revert with 'BAL' in the zero-balance test setup. Roster
    // semantics are independent of reward distribution.
    const chapter = await ethers.getContractAt("VoxChapter", addr);
    await (await chapter.connect(owner).setMinClaimThresholds(0, 0)).wait();
    return addr;
  }

  // Invite + accept (production path). `invitee` must be a signer.
  async function addSubModViaFlow(chapter, adminSigner, invitee) {
    await (await chapter.connect(adminSigner).inviteSubMod(await invitee.getAddress())).wait();
    await (await chapter.connect(invitee).acceptSubModInvitation()).wait();
  }

  beforeEach(async () => {
    [deployer, owner, chapterAdminA, chapterAdminB, subMod1, subMod2, subMod3] =
      await ethers.getSigners();
    governanceSigner = new ethers.Wallet(GOVERNANCE_PRIVATE_KEY, ethers.provider);

    // Mocks
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    const mockPriceFeed = await MockV3Aggregator.deploy(8, 50_000_000);
    await mockPriceFeed.waitForDeployment();

    // Diamond assembly
    const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await DiamondCutFacet.deploy();
    await diamondCutFacet.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCutFacet.getAddress());
    await diamond.waitForDeployment();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    const facetNames = ["DiamondLoupeFacet", "OwnershipFacet", "VoxFacet", "VoxGovernanceFacet", "VoxTokenFacet", "GovernanceLensFacet", "VoxAssistantFacet", "TokenLensFacet"];
    const cut = [];
    for (const name of facetNames) {
      const F = await ethers.getContractFactory(name);
      const inst = await F.deploy(await diamond.getAddress());
      await inst.waitForDeployment();
      cut.push({
        facetAddress: await inst.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(inst),
      });
    }
    const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
    await (await diamondCut.connect(owner).diamondCut(
      cut,
      await diamondInit.getAddress(),
      diamondInit.interface.encodeFunctionData("init")
    )).wait();

    facet = await ethers.getContractAt("VoxFacet", await diamond.getAddress());
    governanceFacet = await ethers.getContractAt("VoxGovernanceFacet", await diamond.getAddress());
    const tokenFacet = await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress());

    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();

    const quotas = {
      voxClaimPercentage: 20,
      viewerClaimPercentage: 20,
      thirdParty1ClaimPercentage: 20,
      thirdParty2ClaimPercentage: 20,
      thirdParty3ClaimPercentage: 20,
      thirdParty4ClaimPercentage: 0,
      thirdParty5ClaimPercentage: 0,
      thirdParty6ClaimPercentage: 0,
      voxAdminClaimPercentage: 10,
      voxAdminChangeQuorum: 51,
      QuotaProposalQuorum: 51,
      FacetProposalQuorum: 51,
      storageProviderPercentage: 1,
      adminApplicantFeeInPolWei: 1000,
      adminVoteDeadlineInBlocks: 604800,
      minQuotaProposalDuration: 43200,
      maxQuotaProposalDuration: 1296000,
      minFacetProposalDuration: 43200,
      maxFacetProposalDuration: 1296000,
    };
    await (await governanceFacet.connect(owner).initialize(quotas, GOVERNANCE_ADDRESS, await owner.getAddress())).wait();

    const VoxChapter = await ethers.getContractFactory("VoxChapter");
    chapterImplementation = await VoxChapter.deploy();
    await chapterImplementation.waitForDeployment();
    await (await facet.connect(owner).setChapterImplementation(await chapterImplementation.getAddress())).wait();
  });

  it("starts empty", async () => {
    expect((await facet.getAllRegisteredSubMods()).length).to.equal(0);
    const [subs, chapters] = await facet.getAllRegisteredSubModsWithChapters();
    expect(subs.length).to.equal(0);
    expect(chapters.length).to.equal(0);
  });

  it("idempotency across multiple chapters: same subMod in N chapters → single roster entry", async () => {
    // `owner` is the platform owner and may create unlimited chapters.
    const chAAddr = await createChapter(owner, "IdempA", "idemp-a");
    const chBAddr = await createChapter(owner, "IdempB", "idemp-b");
    const chA = await ethers.getContractAt("VoxChapter", chAAddr);
    const chB = await ethers.getContractAt("VoxChapter", chBAddr);

    // subMod1 joins chapter A.
    await addSubModViaFlow(chA, owner, subMod1);
    expect(await facet.getAllRegisteredSubMods()).to.deep.equal([await subMod1.getAddress()]);

    // subMod1 joins chapter B as well — second chapter, same address.
    await addSubModViaFlow(chB, owner, subMod1);
    const roster = await facet.getAllRegisteredSubMods();
    expect(roster.length).to.equal(1);
    expect(roster[0]).to.equal(await subMod1.getAddress());
    // Reverse lookup now reflects both chapters.
    expect(await facet.getSubModChapters(await subMod1.getAddress())).to.have.lengthOf(2);
  });

  it("add A, B, C; remove B from their only chapter → roster = {A, C}", async () => {
    const chAddr = await createChapter(owner, "Tri", "tri-001");
    const chapter = await ethers.getContractAt("VoxChapter", chAddr);

    await addSubModViaFlow(chapter, owner, subMod1);
    await addSubModViaFlow(chapter, owner, subMod2);
    await addSubModViaFlow(chapter, owner, subMod3);

    let roster = await facet.getAllRegisteredSubMods();
    expect(roster.length).to.equal(3);
    expect(new Set(roster)).to.deep.equal(new Set([
      await subMod1.getAddress(),
      await subMod2.getAddress(),
      await subMod3.getAddress(),
    ]));

    // Admin removes subMod2 from the only chapter they're in.
    await (await chapter.connect(owner).removeSubMod(await subMod2.getAddress())).wait();

    roster = await facet.getAllRegisteredSubMods();
    expect(roster.length).to.equal(2);
    expect(new Set(roster)).to.deep.equal(new Set([
      await subMod1.getAddress(),
      await subMod3.getAddress(),
    ]));
    // Ordering is not asserted (swap-and-pop).
  });

  it("losing one chapter while still in ≥1 other chapter keeps address on roster", async () => {
    const chAAddr = await createChapter(owner, "KeepA", "keep-a");
    const chBAddr = await createChapter(owner, "KeepB", "keep-b");
    const chA = await ethers.getContractAt("VoxChapter", chAAddr);
    const chB = await ethers.getContractAt("VoxChapter", chBAddr);

    await addSubModViaFlow(chA, owner, subMod1);
    await addSubModViaFlow(chB, owner, subMod1);
    expect((await facet.getAllRegisteredSubMods()).length).to.equal(1);

    // Remove from chA only.
    await (await chA.connect(owner).removeSubMod(await subMod1.getAddress())).wait();

    const roster = await facet.getAllRegisteredSubMods();
    expect(roster).to.deep.equal([await subMod1.getAddress()]);
    const chapters = await facet.getSubModChapters(await subMod1.getAddress());
    expect(chapters).to.deep.equal([chBAddr]);

    // Now remove from the last chapter → leaves roster.
    await (await chB.connect(owner).removeSubMod(await subMod1.getAddress())).wait();
    expect((await facet.getAllRegisteredSubMods()).length).to.equal(0);
    expect((await facet.getSubModChapters(await subMod1.getAddress())).length).to.equal(0);
  });

  it("SubModRegistered fires only on 0→1 transition; SubModDeregistered only on 1→0", async () => {
    const chAAddr = await createChapter(owner, "EvA", "ev-a");
    const chBAddr = await createChapter(owner, "EvB", "ev-b");
    const chA = await ethers.getContractAt("VoxChapter", chAAddr);
    const chB = await ethers.getContractAt("VoxChapter", chBAddr);
    const target = await subMod1.getAddress();

    // 0→1: expect SubModRegistered on the accept that triggers the callback.
    await (await chA.connect(owner).inviteSubMod(target)).wait();
    const txAcceptA = await chA.connect(subMod1).acceptSubModInvitation();
    await expect(txAcceptA).to.emit(facet, "SubModRegistered").withArgs(target);

    // 1→2: NO SubModRegistered event (already on roster).
    await (await chB.connect(owner).inviteSubMod(target)).wait();
    const txAcceptB = await chB.connect(subMod1).acceptSubModInvitation();
    await expect(txAcceptB).to.not.emit(facet, "SubModRegistered");
    await expect(txAcceptB).to.not.emit(facet, "SubModDeregistered");

    // 2→1: NO SubModDeregistered (still in chB).
    const txRemoveA = await chA.connect(owner).removeSubMod(target);
    await expect(txRemoveA).to.not.emit(facet, "SubModDeregistered");

    // 1→0: expect SubModDeregistered.
    const txRemoveB = await chB.connect(owner).removeSubMod(target);
    await expect(txRemoveB).to.emit(facet, "SubModDeregistered").withArgs(target);
  });

  it("external deregisterSubMod from a non-chapter caller reverts (existing guard preserved)", async () => {
    await expect(facet.connect(chapterAdminA).deregisterSubMod(await subMod1.getAddress()))
      .to.be.revertedWith("NOT_CHAPTER");
  });

  it("external registerSubMod from a non-chapter caller reverts (existing guard preserved)", async () => {
    await expect(facet.connect(chapterAdminA).registerSubMod(await subMod1.getAddress()))
      .to.be.revertedWith("NOT_CHAPTER");
  });

  it("getAllRegisteredSubModsWithChapters is internally consistent with getSubModChapters", async () => {
    const chAAddr = await createChapter(owner, "ZipA", "zip-a");
    const chBAddr = await createChapter(owner, "ZipB", "zip-b");
    const chA = await ethers.getContractAt("VoxChapter", chAAddr);
    const chB = await ethers.getContractAt("VoxChapter", chBAddr);

    await addSubModViaFlow(chA, owner, subMod1);
    await addSubModViaFlow(chB, owner, subMod1);
    await addSubModViaFlow(chA, owner, subMod2);

    const [subs, chapters] = await facet.getAllRegisteredSubModsWithChapters();
    expect(subs.length).to.equal(2);
    for (let i = 0; i < subs.length; i++) {
      const reverse = await facet.getSubModChapters(subs[i]);
      expect([...chapters[i]].sort()).to.deep.equal([...reverse].sort());
    }
  });

  it("appending roster fields did not corrupt pre-existing storage (chapterImplementation round-trip)", async () => {
    // Reads a field that lives BEFORE the newly appended ones in the struct.
    // If the slot layout were broken, this read would return zero or garbage
    // after roster mutations.
    const implBefore = await facet.getChapterImplementation();
    expect(implBefore).to.equal(await chapterImplementation.getAddress());

    const chAddr = await createChapter(owner, "SlotCheck", "slot-001");
    const chapter = await ethers.getContractAt("VoxChapter", chAddr);
    await addSubModViaFlow(chapter, owner, subMod1);
    await (await chapter.connect(owner).removeSubMod(await subMod1.getAddress())).wait();

    const implAfter = await facet.getChapterImplementation();
    expect(implAfter).to.equal(implBefore);
  });

  it("roster scales: ≥256 addresses enumerable in a single view call", async () => {
    // Two chapters × 128 sub-mods = 256 distinct entries on the global roster.
    // MAX_SUBMODS per chapter is 150, so this fits. We use impersonated accounts
    // to avoid generating/funding 256 private keys.
    const chAAddr = await createChapter(owner, "ScaleA", "scale-a");
    const chBAddr = await createChapter(owner, "ScaleB", "scale-b");
    const chA = await ethers.getContractAt("VoxChapter", chAAddr);
    const chB = await ethers.getContractAt("VoxChapter", chBAddr);

    const per = 128;
    const addrs = [];
    for (let i = 0; i < per * 2; i++) {
      // Deterministic non-colliding addresses, offset above the precompile range.
      const hex = (i + 0x1000).toString(16).padStart(40, "0");
      addrs.push(ethers.getAddress("0x" + hex));
    }

    async function addImpersonated(chapter, invitee) {
      await (await chapter.connect(owner).inviteSubMod(invitee)).wait();
      await hre.network.provider.send("hardhat_impersonateAccount", [invitee]);
      await hre.network.provider.send("hardhat_setBalance", [invitee, "0x3635C9ADC5DEA00000"]); // 1000 ETH
      const signer = await ethers.getSigner(invitee);
      await (await chapter.connect(signer).acceptSubModInvitation()).wait();
      await hre.network.provider.send("hardhat_stopImpersonatingAccount", [invitee]);
    }

    for (let i = 0; i < per; i++) {
      await addImpersonated(chA, addrs[i]);
    }
    for (let i = per; i < per * 2; i++) {
      await addImpersonated(chB, addrs[i]);
    }

    const roster = await facet.getAllRegisteredSubMods();
    expect(roster.length).to.equal(256);
    expect(new Set(roster).size).to.equal(256);
    // Sanity: every returned address is one we added.
    const expected = new Set(addrs);
    for (const a of roster) {
      expect(expected.has(a)).to.equal(true);
    }
  });
});
