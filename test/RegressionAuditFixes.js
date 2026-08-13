/**
 * Regression tests for the integer-safety audit fixes (F1 / F2 / F3 / F5 / F6).
 *
 * Covers three representative scenarios:
 *   1. Promoted-subMod-owner   — prior subMod claim stamp must not brick the
 *                                new-owner payout path (F1 / F2 / F3).
 *   2. Small-holder USDC       — single-division (MUDS) path pays a non-zero
 *                                reward where the pre-fix two-step scaling
 *                                would truncate to zero (F5).
 *   3. Admin-claim % > 100     — governance initialize() must reject an out-of-
 *                                range voxAdminClaimPercentage (F6).
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");

const GOVERNANCE_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const GOVERNANCE_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

function validQuotas() {
  return {
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
    maxFacetProposalDuration: 1296000
  };
}

async function deployDiamondBare(deployer) {
  const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();

  const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
  const mockPriceFeed = await MockV3Aggregator.deploy(8, 50000000);
  await mockPriceFeed.waitForDeployment();

  const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
  const diamondCutFacet = await DiamondCutFacet.deploy();
  await diamondCutFacet.waitForDeployment();

  const Diamond = await ethers.getContractFactory("Diamond");
  const diamond = await Diamond.deploy(await deployer.getAddress(), await diamondCutFacet.getAddress());
  await diamond.waitForDeployment();

  const DiamondInit = await ethers.getContractFactory("DiamondInit");
  const diamondInit = await DiamondInit.deploy();
  await diamondInit.waitForDeployment();

  const FacetNames = [
    "DiamondLoupeFacet", "OwnershipFacet", "VoxFacet", "VoxGovernanceFacet", "VoxTokenFacet", "GovernanceLensFacet", "VoxAssistantFacet", "TokenLensFacet"];
  const cut = [];
  for (const FacetName of FacetNames) {
    const Facet = await ethers.getContractFactory(FacetName);
    const facetInstance = await Facet.deploy(await diamond.getAddress());
    await facetInstance.waitForDeployment();
    cut.push({
      facetAddress: await facetInstance.getAddress(),
      action: FacetCutAction.Add,
      functionSelectors: getSelectors(facetInstance)
    });
  }

  const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
  const functionCall = diamondInit.interface.encodeFunctionData("init");
  await (await diamondCut.connect(deployer).diamondCut(cut, await diamondInit.getAddress(), functionCall)).wait();

  return {
    diamond,
    mockUSDC,
    mockPriceFeed,
    voxFacet: await ethers.getContractAt("VoxFacet", await diamond.getAddress()),
    governanceFacet: await ethers.getContractAt("VoxGovernanceFacet", await diamond.getAddress()),
    tokenFacet: await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress())
  };
}

describe("Regression — audit fixes F1/F2/F3/F5/F6", function () {
  describe("F1/F2/F3 — promoted-subMod new-owner claim path", function () {
    let deployer, chapterAdmin, subMod1, subMod2;
    let voxFacet, governanceFacet, tokenFacet, mockUSDC;
    let chapter, chapterAddress;

    beforeEach(async () => {
      [deployer, chapterAdmin, subMod1, subMod2] = await ethers.getSigners();
      const governanceSigner = new ethers.Wallet(GOVERNANCE_PRIVATE_KEY, ethers.provider);

      const env = await deployDiamondBare(deployer);
      ({ voxFacet, governanceFacet, tokenFacet, mockUSDC } = env);

      await (await tokenFacet.connect(deployer).initialize(
        await env.diamond.getAddress(),
        await mockUSDC.getAddress(),
        await env.mockPriceFeed.getAddress(),
        await deployer.getAddress()
      )).wait();

      await (await governanceFacet.connect(deployer).initialize(
        validQuotas(),
        GOVERNANCE_ADDRESS,
        await deployer.getAddress()
      )).wait();

      const VoxChapter = await ethers.getContractFactory("VoxChapter");
      const impl = await VoxChapter.deploy();
      await impl.waitForDeployment();
      await (await voxFacet.connect(deployer).setChapterImplementation(await impl.getAddress())).wait();

      const chapterName = "RegChapter";
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const hash = ethers.keccak256(
        ethers.solidityPacked(["string", "address", "uint256"], [chapterName, await chapterAdmin.getAddress(), chainId])
      );
      const sig = await governanceSigner.signMessage(ethers.getBytes(hash));
      await (await voxFacet.connect(chapterAdmin).createChapter(chapterName, "reg-001", sig)).wait();
      chapterAddress = await voxFacet.getChapterAddress(chapterName);
      chapter = await ethers.getContractAt("VoxChapter", chapterAddress);

      // Reduce owner share so subMods accumulate a non-zero per-seat stamp.
      await (await chapter.connect(chapterAdmin).changeChapterOwnerShare(50)).wait();

      // Onboard subMod1 and subMod2.
      await (await chapter.connect(chapterAdmin).inviteSubMod(await subMod1.getAddress())).wait();
      await (await chapter.connect(subMod1).acceptSubModInvitation()).wait();
      await (await chapter.connect(chapterAdmin).inviteSubMod(await subMod2.getAddress())).wait();
      await (await chapter.connect(subMod2).acceptSubModInvitation()).wait();

      // Fund and claim so subMod1 accrues a non-zero polClaimedByUser stamp.
      await deployer.sendTransaction({ to: chapterAddress, value: ethers.parseEther("4.0") });
      await mockUSDC.mint(chapterAddress, ethers.parseUnits("400", 6));
      await (await chapter.connect(deployer).claimChapterRewards()).wait();

      const subMod1POLStamp = await chapter.polClaimedByUser(await subMod1.getAddress());
      expect(subMod1POLStamp).to.be.greaterThan(0);
    });

    it("getPendingRewards for the new (ex-subMod) owner does not underflow", async () => {
      // Promote subMod1 to chapter admin.
      await (await chapter.connect(deployer).setChapterAdmin(await subMod1.getAddress())).wait();

      // Before the fix, calling getPendingRewards on the new owner would revert
      // with arithmetic underflow inside totalAggregateOwnerPOL - polClaimedByUser[owner].
      const [pol, usdc] = await chapter.getPendingRewards(await subMod1.getAddress());
      expect(pol).to.equal(0);
      expect(usdc).to.equal(0);
    });

    it("claimChapterRewards succeeds after promoting an ex-subMod to owner", async () => {
      await (await chapter.connect(deployer).setChapterAdmin(await subMod1.getAddress())).wait();

      // Fresh deposits after rotation — new-owner aggregate starts at 0 but
      // polClaimedByUser[subMod1] carries the old per-seat stamp.
      await deployer.sendTransaction({ to: chapterAddress, value: ethers.parseEther("2.0") });
      await mockUSDC.mint(chapterAddress, ethers.parseUnits("200", 6));

      // Pre-fix: reverts with panic(0x11) arithmetic underflow.
      // Post-fix: completes without reverting; saturating sub clamps claimable to 0.
      await expect(chapter.connect(deployer).claimChapterRewards()).to.not.be.reverted;
    });
  });

  describe("F5 — small-holder USDC reward single-division (MUDS)", function () {
    let deployer, holder;
    let tokenFacet, governanceFacet, mockUSDC, diamondAddr;

    beforeEach(async () => {
      [deployer, holder] = await ethers.getSigners();
      const env = await deployDiamondBare(deployer);
      tokenFacet = env.tokenFacet;
      governanceFacet = env.governanceFacet;
      mockUSDC = env.mockUSDC;
      diamondAddr = await env.diamond.getAddress();

      await (await tokenFacet.connect(deployer).initialize(
        diamondAddr,
        await mockUSDC.getAddress(),
        await env.mockPriceFeed.getAddress(),
        await deployer.getAddress()
      )).wait();

      await (await governanceFacet.connect(deployer).initialize(
        validQuotas(),
        GOVERNANCE_ADDRESS,
        await deployer.getAddress()
      )).wait();
    });

    it("pays a non-zero pending USDC reward to a small holder", async () => {
      // totalSupply = 21e24 wei (21M * 1e18). Give holder 1 whole VOX.
      // With default quotas (storage=1%, admin=10%), a 1000-USDC deposit
      // leaves ~891 USDC (units = wei of 6-dec USDC) in the bounty pool.
      //
      // Two-step (pre-fix) form: (balance*1e18 / ts) * delta / 1e18
      //   holderPct = 1e18*1e18 / 21e24           = 47619  (tiny)
      //   reward    = 47619 * 8.91e8 / 1e18       = 0      (truncates)
      // Single-division (post-fix) form:
      //   reward    = 1e18 * 8.91e8 / 21e24       = 42     (non-zero)
      const oneToken = ethers.parseUnits("1", 18);
      await (await tokenFacet.connect(deployer).transfer(await holder.getAddress(), oneToken)).wait();

      const depositAmount = ethers.parseUnits("1000", 6); // 1e9 units
      await (await mockUSDC.mint(await deployer.getAddress(), depositAmount)).wait();
      await (await mockUSDC.connect(deployer).approve(diamondAddr, depositAmount)).wait();
      await (await tokenFacet.connect(deployer).depositUSDCForRewards(depositAmount)).wait();

      const [, usdcReward] = await tokenFacet.pendingRewards(await holder.getAddress());
      expect(usdcReward).to.be.greaterThan(0);
    });
  });

  describe("F6 — governance bounds on voxAdminClaimPercentage", function () {
    let deployer, governanceFacet;

    beforeEach(async () => {
      [deployer] = await ethers.getSigners();
      const env = await deployDiamondBare(deployer);
      governanceFacet = env.governanceFacet;

      // Token facet must be initialized before governance initialize() is called
      // (the governance init path reads token storage).
      await (await env.tokenFacet.connect(deployer).initialize(
        await env.diamond.getAddress(),
        await env.mockUSDC.getAddress(),
        await env.mockPriceFeed.getAddress(),
        await deployer.getAddress()
      )).wait();
    });

    it("initialize reverts when voxAdminClaimPercentage > 100", async () => {
      const badQuotas = validQuotas();
      badQuotas.voxAdminClaimPercentage = 101;

      await expect(
        governanceFacet.connect(deployer).initialize(badQuotas, GOVERNANCE_ADDRESS, await deployer.getAddress())
      ).to.be.revertedWith("Invalid admin claim percentage");
    });

    it("initialize succeeds at the boundary (100)", async () => {
      const goodQuotas = validQuotas();
      // Zero out other pcts to keep internal sum invariants satisfied if any.
      goodQuotas.voxAdminClaimPercentage = 100;

      await expect(
        governanceFacet.connect(deployer).initialize(goodQuotas, GOVERNANCE_ADDRESS, await deployer.getAddress())
      ).to.not.be.reverted;
    });
  });
});
