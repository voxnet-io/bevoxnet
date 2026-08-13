/**
 * @title Platform Ban Global Roster — Forward Enumeration Tests
 * @notice Covers the new getAllPlatformBannedUsers() view on VoxFacet and
 *         the swap-and-pop invariants of the platform-ban roster maintained
 *         inside VoxGovernanceFacet.banUserFromPlatform /
 *         unbanUserFromPlatform.
 *
 * Invariants asserted:
 *   - An address appears in getAllPlatformBannedUsers() iff
 *     isUserBannedFromPlatform(addr) is true.
 *   - Ban A, B, C → roster = {A, B, C} (order not asserted; swap-and-pop).
 *   - Unban B while A, C remain → roster = {A, C}.
 *   - Double-ban reverts with the existing guard ("User is already banned").
 *   - Unban of a non-banned address reverts ("User is not banned").
 *   - UserBanned event fires exactly once on the 0→1 transition; re-ban
 *     reverts before emitting a duplicate. UserUnbanned fires on 1→0.
 *   - Pre-existing storage (e.g., chapterImplementation) is not corrupted by
 *     ban/unban mutations — confirming the struct-append was slot-safe.
 *   - ≥256 banned addresses enumerable in a single view call.
 *
 * Note: banUserFromPlatform auto-revokes VoxAssistant roles and invitations as
 * a side-effect; these tests do not exercise that path (covered elsewhere).
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const hre = require("hardhat");

const GOVERNANCE_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const GOVERNANCE_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

describe("VoxGovernanceFacet — platform-ban roster (getAllPlatformBannedUsers)", function () {
  this.timeout(300_000);

  let deployer, owner, userA, userB, userC, other;
  let facet, governanceFacet, governanceLensFacet, diamond;
  let chapterImplementation;
  let governanceSigner;

  beforeEach(async () => {
    [deployer, owner, userA, userB, userC, other] = await ethers.getSigners();
    governanceSigner = new ethers.Wallet(GOVERNANCE_PRIVATE_KEY, ethers.provider);

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    const mockPriceFeed = await MockV3Aggregator.deploy(8, 50_000_000);
    await mockPriceFeed.waitForDeployment();

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
    governanceLensFacet = await ethers.getContractAt("GovernanceLensFacet", await diamond.getAddress());
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
    expect((await facet.getAllPlatformBannedUsers()).length).to.equal(0);
  });

  it("ban A, B, C → roster contains all three (order not asserted)", async () => {
    const a = await userA.getAddress();
    const b = await userB.getAddress();
    const c = await userC.getAddress();
    await (await governanceFacet.connect(owner).banUserFromPlatform(a)).wait();
    await (await governanceFacet.connect(owner).banUserFromPlatform(b)).wait();
    await (await governanceFacet.connect(owner).banUserFromPlatform(c)).wait();

    const roster = await facet.getAllPlatformBannedUsers();
    expect(roster.length).to.equal(3);
    expect(new Set(roster)).to.deep.equal(new Set([a, b, c]));
    // Reverse lookup agrees.
    expect(await facet.isUserBannedFromPlatform(a)).to.equal(true);
    expect(await facet.isUserBannedFromPlatform(b)).to.equal(true);
    expect(await facet.isUserBannedFromPlatform(c)).to.equal(true);
  });

  it("unban middle entry: ban A,B,C then unban B → roster = {A, C}", async () => {
    const a = await userA.getAddress();
    const b = await userB.getAddress();
    const c = await userC.getAddress();
    await (await governanceFacet.connect(owner).banUserFromPlatform(a)).wait();
    await (await governanceFacet.connect(owner).banUserFromPlatform(b)).wait();
    await (await governanceFacet.connect(owner).banUserFromPlatform(c)).wait();

    await (await governanceFacet.connect(owner).unbanUserFromPlatform(b)).wait();

    const roster = await facet.getAllPlatformBannedUsers();
    expect(roster.length).to.equal(2);
    expect(new Set(roster)).to.deep.equal(new Set([a, c]));
    expect(await facet.isUserBannedFromPlatform(b)).to.equal(false);
  });

  it("unban first entry: ban A,B,C then unban A → roster = {B, C}", async () => {
    const a = await userA.getAddress();
    const b = await userB.getAddress();
    const c = await userC.getAddress();
    await (await governanceFacet.connect(owner).banUserFromPlatform(a)).wait();
    await (await governanceFacet.connect(owner).banUserFromPlatform(b)).wait();
    await (await governanceFacet.connect(owner).banUserFromPlatform(c)).wait();

    await (await governanceFacet.connect(owner).unbanUserFromPlatform(a)).wait();

    const roster = await facet.getAllPlatformBannedUsers();
    expect(roster.length).to.equal(2);
    expect(new Set(roster)).to.deep.equal(new Set([b, c]));
  });

  it("unban last entry: ban A,B,C then unban C → roster = {A, B}", async () => {
    const a = await userA.getAddress();
    const b = await userB.getAddress();
    const c = await userC.getAddress();
    await (await governanceFacet.connect(owner).banUserFromPlatform(a)).wait();
    await (await governanceFacet.connect(owner).banUserFromPlatform(b)).wait();
    await (await governanceFacet.connect(owner).banUserFromPlatform(c)).wait();

    await (await governanceFacet.connect(owner).unbanUserFromPlatform(c)).wait();

    const roster = await facet.getAllPlatformBannedUsers();
    expect(roster.length).to.equal(2);
    expect(new Set(roster)).to.deep.equal(new Set([a, b]));
  });

  it("re-ban-after-unban cycles end with a single roster entry and correct flag", async () => {
    const a = await userA.getAddress();
    for (let i = 0; i < 4; i++) {
      await (await governanceFacet.connect(owner).banUserFromPlatform(a)).wait();
      expect((await facet.getAllPlatformBannedUsers()).length).to.equal(1);
      await (await governanceFacet.connect(owner).unbanUserFromPlatform(a)).wait();
      expect((await facet.getAllPlatformBannedUsers()).length).to.equal(0);
    }
    expect(await facet.isUserBannedFromPlatform(a)).to.equal(false);
  });

  it("double-ban reverts (existing guard preserved)", async () => {
    const a = await userA.getAddress();
    await (await governanceFacet.connect(owner).banUserFromPlatform(a)).wait();
    await expect(governanceFacet.connect(owner).banUserFromPlatform(a))
      .to.be.revertedWith("User is already banned");
  });

  it("unban of non-banned address reverts (existing guard preserved)", async () => {
    const a = await userA.getAddress();
    await expect(governanceFacet.connect(owner).unbanUserFromPlatform(a))
      .to.be.revertedWith("User is not banned");
  });

  it("UserBanned fires on 0→1 transition; UserUnbanned fires on 1→0", async () => {
    const a = await userA.getAddress();

    const txBan = await governanceFacet.connect(owner).banUserFromPlatform(a);
    // UserBanned(address indexed user, uint256 blockNumber)
    await expect(txBan).to.emit(governanceFacet, "UserBanned");

    // Re-ban in same receipt path is guarded by require; no duplicate event.
    await expect(governanceFacet.connect(owner).banUserFromPlatform(a))
      .to.be.revertedWith("User is already banned");

    const txUnban = await governanceFacet.connect(owner).unbanUserFromPlatform(a);
    await expect(txUnban).to.emit(governanceFacet, "UserUnbanned");
  });

  it("non-owner / non-VoxAssistant cannot call ban or unban (existing gate preserved)", async () => {
    const a = await userA.getAddress();
    await expect(governanceFacet.connect(other).banUserFromPlatform(a))
      .to.be.revertedWith("VOXA");
    // Prep state for unban check as owner.
    await (await governanceFacet.connect(owner).banUserFromPlatform(a)).wait();
    await expect(governanceFacet.connect(other).unbanUserFromPlatform(a))
      .to.be.revertedWith("VOXA");
  });

  it("appending roster fields did not corrupt pre-existing storage (chapterImplementation round-trip)", async () => {
    const implBefore = await facet.getChapterImplementation();
    expect(implBefore).to.equal(await chapterImplementation.getAddress());

    const a = await userA.getAddress();
    const b = await userB.getAddress();
    await (await governanceFacet.connect(owner).banUserFromPlatform(a)).wait();
    await (await governanceFacet.connect(owner).banUserFromPlatform(b)).wait();
    await (await governanceFacet.connect(owner).unbanUserFromPlatform(a)).wait();

    const implAfter = await facet.getChapterImplementation();
    expect(implAfter).to.equal(implBefore);
  });

  it("getUserPlatformBanBlockNumber tracks ban block (renamed from getUserBanBlockNumber)", async () => {
    const a = await userA.getAddress();
    expect(await governanceLensFacet.getUserPlatformBanBlockNumber(a)).to.equal(0);
    const tx = await governanceFacet.connect(owner).banUserFromPlatform(a);
    const receipt = await tx.wait();
    expect(await governanceLensFacet.getUserPlatformBanBlockNumber(a)).to.equal(receipt.blockNumber);
    // Unban keeps the block number per the NatSpec contract.
    await (await governanceFacet.connect(owner).unbanUserFromPlatform(a)).wait();
    expect(await governanceLensFacet.getUserPlatformBanBlockNumber(a)).to.equal(receipt.blockNumber);
  });

  it("roster scales: ≥256 banned addresses enumerable in a single view call", async () => {
    // Deterministic non-colliding addresses, offset above precompile range.
    const addrs = [];
    for (let i = 0; i < 256; i++) {
      const hex = (i + 0x20000).toString(16).padStart(40, "0");
      addrs.push(ethers.getAddress("0x" + hex));
    }

    for (const a of addrs) {
      await (await governanceFacet.connect(owner).banUserFromPlatform(a)).wait();
    }

    const roster = await facet.getAllPlatformBannedUsers();
    expect(roster.length).to.equal(256);
    expect(new Set(roster).size).to.equal(256);
    const expected = new Set(addrs);
    for (const a of roster) {
      expect(expected.has(a)).to.equal(true);
    }
  });
});
