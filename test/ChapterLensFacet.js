/**
 * @title ChapterLensFacet Test Suite
 * @notice Verifies the aggregating view-only lens facet against ground-truth
 *         from individual chapter / Diamond facet getters.
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

const GOVERNANCE_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const GOVERNANCE_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

describe("ChapterLensFacet", function () {
  let deployer, owner, alice, bob, carol;
  let diamond, diamondAddress;
  let voxFacet, governanceFacet, lensFacet;
  let mockUSDC, mockPriceFeed;
  let governanceSigner;

  async function signChapter(name, caller) {
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const hash = ethers.keccak256(
      ethers.solidityPacked(["string", "address", "uint256"], [name, caller, chainId])
    );
    return governanceSigner.signMessage(ethers.getBytes(hash));
  }

  async function createChapter(caller, name, id) {
    const sig = await signChapter(name, await caller.getAddress());
    return voxFacet.connect(caller).createChapter(name, id, sig);
  }

  beforeEach(async () => {
    [deployer, owner, alice, bob, carol] = await ethers.getSigners();
    governanceSigner = new ethers.Wallet(GOVERNANCE_PRIVATE_KEY, ethers.provider);

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3 = await ethers.getContractFactory("MockV3Aggregator");
    mockPriceFeed = await MockV3.deploy(8, 50000000);
    await mockPriceFeed.waitForDeployment();

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCut = await DiamondCutFacet.deploy();
    await diamondCut.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCut.getAddress());
    await diamond.waitForDeployment();
    diamondAddress = await diamond.getAddress();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    const FacetNames = [
      "DiamondLoupeFacet",
      "OwnershipFacet",
      "VoxFacet",
      "VoxGovernanceFacet",
      "VoxTokenFacet",
      "ChapterLensFacet",
    ];

    const cut = [];
    for (const name of FacetNames) {
      const F = await ethers.getContractFactory(name);
      const f = await F.deploy(diamondAddress);
      await f.waitForDeployment();
      cut.push({
        facetAddress: await f.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(f),
      });
    }

    const cutter = await ethers.getContractAt("IDiamondCut", diamondAddress);
    const initData = diamondInit.interface.encodeFunctionData("init");
    await (await cutter.connect(owner).diamondCut(cut, await diamondInit.getAddress(), initData)).wait();

    voxFacet = await ethers.getContractAt("VoxFacet", diamondAddress);
    governanceFacet = await ethers.getContractAt("VoxGovernanceFacet", diamondAddress);
    lensFacet = await ethers.getContractAt("ChapterLensFacet", diamondAddress);
    const tokenFacet = await ethers.getContractAt("VoxTokenFacet", diamondAddress);

    await tokenFacet.connect(owner).initialize(
      diamondAddress,
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    );

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
    await governanceFacet
      .connect(owner)
      .initialize(quotas, GOVERNANCE_ADDRESS, await owner.getAddress());

    const VoxChapter = await ethers.getContractFactory("VoxChapter");
    const impl = await VoxChapter.deploy();
    await impl.waitForDeployment();
    await voxFacet.connect(owner).setChapterImplementation(await impl.getAddress());
  });

  // ============================================================
  // getChapterAdminSnapshot
  // ============================================================
  describe("getChapterAdminSnapshot", () => {
    it("returns zero-initialised struct for codeless address", async () => {
      const snap = await lensFacet.getChapterAdminSnapshot(ethers.ZeroAddress);
      expect(snap.stats.owner).to.equal(ethers.ZeroAddress);
      expect(snap.stats.subModsList.length).to.equal(0);
      expect(snap.bannedUsers.length).to.equal(0);
      expect(snap.pendingInvitations.length).to.equal(0);
      expect(snap.totalShare).to.equal(0);
      expect(snap.diamondAddressRef).to.equal(ethers.ZeroAddress);
    });

    it("matches individual getter outputs after chapter creation", async () => {
      await createChapter(alice, "Chapter A", "A");
      const chapterAddr = await voxFacet.getChapterAddress("Chapter A");
      const chapter = await ethers.getContractAt("VoxChapter", chapterAddr);

      const snap = await lensFacet.getChapterAdminSnapshot(chapterAddr);

      // Stats parity with getChapterStats
      const stats = await chapter.getChapterStats();
      expect(snap.stats.name).to.equal(stats[0]);
      expect(snap.stats.id).to.equal(stats[1]);
      expect(snap.stats.owner).to.equal(stats[2]);
      expect(snap.stats.ownerShare).to.equal(stats[3]);
      expect(snap.stats.subModCount).to.equal(stats[4]);
      expect(snap.stats.polBalance).to.equal(stats[5]);
      expect(snap.stats.usdcBalance).to.equal(stats[6]);
      expect(snap.stats.subModsList.length).to.equal(stats[7].length);

      // Scalars
      expect(snap.totalShare).to.equal(await chapter.totalShare());
      expect(snap.totalPOLDistributed).to.equal(await chapter.totalPOLDistributed());
      expect(snap.totalUSDCDistributed).to.equal(await chapter.totalUSDCDistributed());
      expect(snap.lastKnownPOLBalance).to.equal(await chapter.lastKnownPOLBalance());
      expect(snap.lastKnownUSDCBalance).to.equal(await chapter.lastKnownUSDCBalance());
      expect(snap.lastDistributionTimestamp).to.equal(await chapter.lastDistributionTimestamp());
      expect(snap.diamondAddressRef).to.equal(await chapter.diamondAddress());

      const [polT, usdcT] = await chapter.getMinClaimThresholds();
      expect(snap.polThreshold).to.equal(polT);
      expect(snap.usdcThreshold).to.equal(usdcT);

      // pendingInvitations: returnInvitations() is auth-gated to chapter owner.
      // Lens calls from Diamond → reverts → swallowed → empty.
      expect(snap.pendingInvitations.length).to.equal(0);

      // bannedUsers from getBannedUsersArray
      const banned = await chapter.getBannedUsersArray();
      expect(snap.bannedUsers.length).to.equal(banned.length);
    });
  });

  // ============================================================
  // getUserChapterSnapshot
  // ============================================================
  describe("getUserChapterSnapshot", () => {
    it("returns zero struct when user is address(0)", async () => {
      await createChapter(alice, "Chapter B", "B");
      const chapterAddr = await voxFacet.getChapterAddress("Chapter B");
      const snap = await lensFacet.getUserChapterSnapshot(chapterAddr, ethers.ZeroAddress);
      expect(snap.invited).to.equal(false);
      expect(snap.pendingInvited).to.equal(false);
      expect(snap.invitedAt).to.equal(0);
      expect(snap.pendingPOL).to.equal(0);
      expect(snap.pendingUSDC).to.equal(0);
      expect(snap.lifetimePOL).to.equal(0);
      expect(snap.lifetimeUSDC).to.equal(0);
    });

    it("returns zero struct when chapter is codeless", async () => {
      const snap = await lensFacet.getUserChapterSnapshot(ethers.ZeroAddress, await bob.getAddress());
      expect(snap.invited).to.equal(false);
      expect(snap.lifetimePOL).to.equal(0);
    });

    it("reflects pending invitation state after invite", async () => {
      await createChapter(alice, "Chapter C", "C");
      const chapterAddr = await voxFacet.getChapterAddress("Chapter C");
      const chapter = await ethers.getContractAt("VoxChapter", chapterAddr);

      // alice (chapter owner) invites bob
      await chapter.connect(alice).inviteSubMod(await bob.getAddress());

      const snap = await lensFacet.getUserChapterSnapshot(chapterAddr, await bob.getAddress());
      expect(snap.invited).to.equal(true);
      expect(snap.pendingInvited).to.equal(true);
      expect(snap.invitedAt).to.be.gt(0);

      // Cross-check raw getters
      const [invited, ts] = await chapter.getPendingInvitationDetails(await bob.getAddress());
      expect(snap.pendingInvited).to.equal(invited);
      expect(snap.invitedAt).to.equal(ts);

      const [pol, usdc] = await chapter.getUserLifetimeEarnings(await bob.getAddress());
      expect(snap.lifetimePOL).to.equal(pol);
      expect(snap.lifetimeUSDC).to.equal(usdc);
    });
  });

  // ============================================================
  // getBannedUsersWithBlocks
  // ============================================================
  describe("getBannedUsersWithBlocks", () => {
    it("returns empty parallel arrays for codeless chapter", async () => {
      const [users, blocks] = await lensFacet.getBannedUsersWithBlocks(ethers.ZeroAddress);
      expect(users.length).to.equal(0);
      expect(blocks.length).to.equal(0);
    });

    it("returns banned users with matching ban-block numbers in array order", async () => {
      await createChapter(alice, "Chapter D", "D");
      const chapterAddr = await voxFacet.getChapterAddress("Chapter D");
      const chapter = await ethers.getContractAt("VoxChapter", chapterAddr);

      // Ban two users at different blocks
      await chapter.connect(alice).banUserFromChapter(await bob.getAddress());
      const banBlockBob = await chapter.getUserChapterBanBlockNumber(await bob.getAddress());

      await chapter.connect(alice).banUserFromChapter(await carol.getAddress());
      const banBlockCarol = await chapter.getUserChapterBanBlockNumber(await carol.getAddress());

      const [users, blocks] = await lensFacet.getBannedUsersWithBlocks(chapterAddr);
      const groundTruth = await chapter.getBannedUsersArray();

      expect(users.length).to.equal(groundTruth.length);
      expect(blocks.length).to.equal(users.length);
      for (let i = 0; i < users.length; i++) {
        expect(users[i]).to.equal(groundTruth[i]);
        const expected = await chapter.getUserChapterBanBlockNumber(users[i]);
        expect(blocks[i]).to.equal(expected);
      }
      // Sanity: both users present
      expect(users).to.include(await bob.getAddress());
      expect(users).to.include(await carol.getAddress());
      expect(banBlockBob).to.be.gt(0);
      expect(banBlockCarol).to.be.gt(0);
    });
  });

  // ============================================================
  // getCrossChapterUserContext
  // ============================================================
  describe("getCrossChapterUserContext", () => {
    it("reverts when pageSize exceeds MAX_CROSS_CHAPTER_PAGE_SIZE", async () => {
      await expect(
        lensFacet.getCrossChapterUserContext(await bob.getAddress(), 0, 101)
      ).to.be.revertedWith("pageSize too large");
    });

    it("returns empty rows + real totalChapters when user is address(0)", async () => {
      await createChapter(alice, "Ch1", "1");
      const [rows, total] = await lensFacet.getCrossChapterUserContext(ethers.ZeroAddress, 0, 50);
      expect(rows.length).to.equal(0);
      expect(total).to.equal(1);
    });

    it("returns empty rows when offset >= totalChapters", async () => {
      await createChapter(alice, "Ch1", "1");
      const [rows, total] = await lensFacet.getCrossChapterUserContext(
        await bob.getAddress(),
        5,
        50
      );
      expect(rows.length).to.equal(0);
      expect(total).to.equal(1);
    });

    it("aggregates per-chapter user state across multiple chapters with pagination", async () => {
      // alice creates Ch1; owner (platform owner can multi-create) creates Ch2/Ch3
      await createChapter(alice, "Ch1", "1");
      await createChapter(owner, "Ch2", "2");
      await createChapter(owner, "Ch3", "3");

      const ch1Addr = await voxFacet.getChapterAddress("Ch1");
      const ch2Addr = await voxFacet.getChapterAddress("Ch2");
      const ch1 = await ethers.getContractAt("VoxChapter", ch1Addr);
      const ch2 = await ethers.getContractAt("VoxChapter", ch2Addr);

      // Invite bob to Ch1 and Ch2
      await ch1.connect(alice).inviteSubMod(await bob.getAddress());
      await ch2.connect(owner).inviteSubMod(await bob.getAddress());

      // Page 1: offset=0, size=2 → Ch1, Ch2
      const [rowsP1, total] = await lensFacet.getCrossChapterUserContext(
        await bob.getAddress(),
        0,
        2
      );
      expect(total).to.equal(3);
      expect(rowsP1.length).to.equal(2);

      const namesP1 = rowsP1.map((r) => r.chapterName);
      expect(namesP1).to.include("Ch1");
      expect(namesP1).to.include("Ch2");
      for (const r of rowsP1) {
        expect(r.invited).to.equal(true);
        expect(r.pendingInvited).to.equal(true);
        expect(r.invitedAt).to.be.gt(0);
      }

      // Page 2: offset=2, size=2 → Ch3 (no invite for bob)
      const [rowsP2] = await lensFacet.getCrossChapterUserContext(
        await bob.getAddress(),
        2,
        2
      );
      expect(rowsP2.length).to.equal(1);
      expect(rowsP2[0].chapterName).to.equal("Ch3");
      expect(rowsP2[0].invited).to.equal(false);
      expect(rowsP2[0].pendingInvited).to.equal(false);
    });

    it("accepts pageSize == MAX_CROSS_CHAPTER_PAGE_SIZE (100)", async () => {
      await createChapter(alice, "OnlyOne", "1");
      const [rows, total] = await lensFacet.getCrossChapterUserContext(
        await bob.getAddress(),
        0,
        100
      );
      expect(total).to.equal(1);
      expect(rows.length).to.equal(1);
    });
  });
});
