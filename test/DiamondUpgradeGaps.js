// DiamondUpgradeGaps.js
// Supplemental tests covering gaps in diamond-upgrade coverage:
//   1. Access control on diamondCut (non-owner + post-transferOwnership)
//   2. The _init / _calldata path (delegatecall into an initializer)
//   3. Negative cuts (LibDiamondCut revert strings)
//   4. End-to-end governance-proposed upgrade (createProposal + vote + ratifyUpgrade)
//
// Run with: npx hardhat test test/DiamondUpgradeGaps.js

/* global describe it ethers */

const { expect } = require('chai')
const { loadFixture, mine } = require('@nomicfoundation/hardhat-network-helpers')

const { FacetCutAction, getSelectors } = require('../scripts/libraries/diamond.js')
const { deployDiamond } = require('../scripts/deploy.js')

// LibDiamond revert strings (copied verbatim from contracts/libraries/LibDiamond.sol)
const ERR_NOT_OWNER = 'LibDiamond: Must be contract owner'
const ERR_NO_SELECTORS = 'LibDiamondCut: No selectors in facet to cut'
const ERR_ADD_ZERO_FACET = "LibDiamondCut: Add facet can't be address(0)"
const ERR_ADD_EXISTS = "LibDiamondCut: Can't add function that already exists"
const ERR_REPLACE_SAME = "LibDiamondCut: Can't replace function with same function"
const ERR_REMOVE_NONZERO = 'LibDiamondCut: Remove facet address must be address(0)'
const ERR_REMOVE_MISSING = "LibDiamondCut: Can't remove function that doesn't exist"

async function deployFixture () {
  const [owner, addr1, addr2] = await ethers.getSigners()

  const diamondAddress = await deployDiamond()
  const diamondCutFacet = await ethers.getContractAt('DiamondCutFacet', diamondAddress)
  const diamondLoupeFacet = await ethers.getContractAt('DiamondLoupeFacet', diamondAddress)
  const ownershipFacet = await ethers.getContractAt('OwnershipFacet', diamondAddress)
  const governanceFacet = await ethers.getContractAt('VoxGovernanceFacet', diamondAddress)
  const tokenFacet = await ethers.getContractAt('VoxTokenFacet', diamondAddress)

  // Scratch facet used as the subject of most cuts
  const Test1Facet = await ethers.getContractFactory('Test1Facet')
  const test1 = await Test1Facet.deploy()
  await test1.waitForDeployment()

  // Test1Facet also defines supportsInterface(bytes4), which is already
  // registered by DiamondLoupeFacet on the deployed diamond — strip it so
  // our Add cuts don't collide.
  const test1Selectors = getSelectors(test1).remove(['supportsInterface(bytes4)'])

  return {
    diamondAddress,
    diamondCutFacet,
    diamondLoupeFacet,
    ownershipFacet,
    governanceFacet,
    tokenFacet,
    test1,
    test1Selectors,
    owner,
    addr1,
    addr2
  }
}

describe('DiamondUpgradeGaps', function () {
  // --------------------------------------------------------------
  // 1. Access control on diamondCut
  // --------------------------------------------------------------
  describe('Access control on diamondCut', function () {
    it('reverts when a non-owner calls diamondCut', async function () {
      const { diamondCutFacet, test1, test1Selectors, addr1 } = await loadFixture(deployFixture)

      const cut = [{
        facetAddress: await test1.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: test1Selectors
      }]

      await expect(
        diamondCutFacet.connect(addr1).diamondCut(cut, ethers.ZeroAddress, '0x')
      ).to.be.revertedWith(ERR_NOT_OWNER)
    })

    it('transferOwnership revokes the old owner and grants the new owner', async function () {
      const { diamondCutFacet, ownershipFacet, test1, test1Selectors, owner, addr1 } =
        await loadFixture(deployFixture)

      await ownershipFacet.connect(owner).transferOwnership(addr1.address)
      expect(await ownershipFacet.owner()).to.equal(addr1.address)

      const cut = [{
        facetAddress: await test1.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: test1Selectors
      }]

      // Old owner no longer authorised
      await expect(
        diamondCutFacet.connect(owner).diamondCut(cut, ethers.ZeroAddress, '0x')
      ).to.be.revertedWith(ERR_NOT_OWNER)

      // New owner is authorised
      await expect(
        diamondCutFacet.connect(addr1).diamondCut(cut, ethers.ZeroAddress, '0x')
      ).to.not.be.reverted
    })
  })

  // --------------------------------------------------------------
  // 2. The _init / _calldata path
  // --------------------------------------------------------------
  describe('_init / _calldata delegatecall path', function () {
    it('invokes the initializer during diamondCut', async function () {
      const { diamondCutFacet, diamondLoupeFacet, test1, test1Selectors, owner } =
        await loadFixture(deployFixture)

      const DiamondInit = await ethers.getContractFactory('DiamondInit')
      const diamondInit = await DiamondInit.deploy()
      await diamondInit.waitForDeployment()
      const initCalldata = diamondInit.interface.encodeFunctionData('init', [])

      const cut = [{
        facetAddress: await test1.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: test1Selectors
      }]

      await expect(
        diamondCutFacet.connect(owner).diamondCut(
          cut,
          await diamondInit.getAddress(),
          initCalldata
        )
      ).to.not.be.reverted

      // Verify the cut was applied via the loupe
      const facetForFirst = await diamondLoupeFacet.facetAddress(test1Selectors[0])
      expect(facetForFirst).to.equal(await test1.getAddress())
    })

    it('reverts when _init has no code', async function () {
      const { diamondCutFacet, test1, test1Selectors, owner, addr1 } = await loadFixture(deployFixture)

      const cut = [{
        facetAddress: await test1.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: test1Selectors
      }]

      // addr1 is an EOA → no code → should revert in enforceHasContractCode
      await expect(
        diamondCutFacet.connect(owner).diamondCut(cut, addr1.address, '0x1234')
      ).to.be.revertedWith('LibDiamondCut: _init address has no code')
    })
  })

  // --------------------------------------------------------------
  // 3. Negative cuts
  // --------------------------------------------------------------
  describe('Negative cuts', function () {
    it('reverts when adding with zero facet address', async function () {
      const { diamondCutFacet, test1Selectors, owner } = await loadFixture(deployFixture)

      const cut = [{
        facetAddress: ethers.ZeroAddress,
        action: FacetCutAction.Add,
        functionSelectors: test1Selectors
      }]

      await expect(
        diamondCutFacet.connect(owner).diamondCut(cut, ethers.ZeroAddress, '0x')
      ).to.be.revertedWith(ERR_ADD_ZERO_FACET)
    })

    it('reverts when adding a selector that already exists', async function () {
      const { diamondCutFacet, test1, test1Selectors, owner } = await loadFixture(deployFixture)

      const cut = [{
        facetAddress: await test1.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: test1Selectors
      }]

      // First add succeeds
      await diamondCutFacet.connect(owner).diamondCut(cut, ethers.ZeroAddress, '0x')

      // Second add of the same selectors must revert
      await expect(
        diamondCutFacet.connect(owner).diamondCut(cut, ethers.ZeroAddress, '0x')
      ).to.be.revertedWith(ERR_ADD_EXISTS)
    })

    it('reverts when replacing a function with the same facet', async function () {
      const { diamondCutFacet, test1, test1Selectors, owner } = await loadFixture(deployFixture)

      const selectors = test1Selectors

      // Add first
      await diamondCutFacet.connect(owner).diamondCut(
        [{ facetAddress: await test1.getAddress(), action: FacetCutAction.Add, functionSelectors: selectors }],
        ethers.ZeroAddress,
        '0x'
      )

      // Replace with the same facet → revert
      await expect(
        diamondCutFacet.connect(owner).diamondCut(
          [{ facetAddress: await test1.getAddress(), action: FacetCutAction.Replace, functionSelectors: selectors }],
          ethers.ZeroAddress,
          '0x'
        )
      ).to.be.revertedWith(ERR_REPLACE_SAME)
    })

    it('reverts when removing with non-zero facet address', async function () {
      const { diamondCutFacet, test1, test1Selectors, owner } = await loadFixture(deployFixture)

      const cut = [{
        facetAddress: await test1.getAddress(), // must be address(0) for Remove
        action: FacetCutAction.Remove,
        functionSelectors: test1Selectors
      }]

      await expect(
        diamondCutFacet.connect(owner).diamondCut(cut, ethers.ZeroAddress, '0x')
      ).to.be.revertedWith(ERR_REMOVE_NONZERO)
    })

    it("reverts when removing a selector that doesn't exist", async function () {
      const { diamondCutFacet, owner } = await loadFixture(deployFixture)

      const bogusSelector = '0xdeadbeef'
      const cut = [{
        facetAddress: ethers.ZeroAddress,
        action: FacetCutAction.Remove,
        functionSelectors: [bogusSelector]
      }]

      await expect(
        diamondCutFacet.connect(owner).diamondCut(cut, ethers.ZeroAddress, '0x')
      ).to.be.revertedWith(ERR_REMOVE_MISSING)
    })

    it('reverts when a cut has an empty selector array', async function () {
      const { diamondCutFacet, test1, owner } = await loadFixture(deployFixture)
      // test1 only used for the facet address; empty selector array triggers the revert

      const cut = [{
        facetAddress: await test1.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: []
      }]

      await expect(
        diamondCutFacet.connect(owner).diamondCut(cut, ethers.ZeroAddress, '0x')
      ).to.be.revertedWith(ERR_NO_SELECTORS)
    })
  })

  // --------------------------------------------------------------
  // 4. End-to-end governance-proposed upgrade
  // --------------------------------------------------------------
  describe('Governance-proposed upgrade (FacetProposal)', function () {
    const MIN_FACET_DURATION = 43200 // matches deploy.js default

    // `ratifyUpgrade` applies the vote-ratified FacetCut via an internal
    // `LibDiamond.diamondCut(...)` call, which bypasses the owner-only
    // `DiamondCutFacet` entry point. The governance vote itself is the
    // authorization (see comment on ratifyUpgrade).
    it('creates, votes on, and ratifies a FacetProposal that adds Test1Facet selectors', async function () {
      const {
        diamondAddress,
        diamondLoupeFacet,
        governanceFacet,
        tokenFacet,
        test1,
        test1Selectors,
        owner
      } = await loadFixture(deployFixture)

      const facetCuts = [{
        facetAddress: await test1.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: test1Selectors
      }]

      // Dummy quota struct (unused for FacetProposal but required by the signature)
      const dummyQuota = {
        proposedVoxClaimPercentage: 0,
        proposedViewerClaimPercentage: 0,
        proposedThirdParty1ClaimPercentage: 0,
        proposedThirdParty2ClaimPercentage: 0,
        proposedThirdParty3ClaimPercentage: 0,
        proposedThirdParty4ClaimPercentage: 0,
        proposedThirdParty5ClaimPercentage: 0,
        proposedThirdParty6ClaimPercentage: 0,
        proposedVoxAdminClaimPercentage: 0,
        proposedVoxAdminChangeQuorum: 0,
        proposedQuotaProposalQuorum: 0,
        proposedFacetProposalQuorum: 0,
        proposedStorageProviderPercentage: 0,
        proposedAdminApplicantFeeInPolWei: 0,
        proposedAdminVoteDeadlineInBlocks: 0,
        proposedMinQuotaProposalDuration: 0,
        proposedMaxQuotaProposalDuration: 0,
        proposedMinFacetProposalDuration: 0,
        proposedMaxFacetProposalDuration: 0
      }

      // Mine a couple of blocks to clear any lingering mint cooldown
      await mine(5)

      // ProposalType: 0 = QuotaProposal, 1 = FacetProposal
      await governanceFacet.connect(owner).createProposal(
        1,
        dummyQuota,
        MIN_FACET_DURATION,
        facetCuts,
        ethers.ZeroAddress,
        '0x'
      )

      // Owner holds full initial supply → their single support vote easily
      // exceeds the 51% FacetProposalQuorum default.
      const ownerBal = await tokenFacet.balanceOf(owner.address)
      expect(ownerBal).to.be.gt(0n)

      await governanceFacet.connect(owner).voteOnProposal(true)

      // Advance past the voting deadline
      await mine(MIN_FACET_DURATION + 1)

      // Ratify → internally performs diamondCut with the proposed facet cuts
      await expect(governanceFacet.connect(owner).ratifyUpgrade()).to.not.be.reverted

      // Verify via loupe: selectors now resolve to the Test1Facet address
      for (const sel of test1Selectors) {
        expect(await diamondLoupeFacet.facetAddress(sel)).to.equal(await test1.getAddress())
      }

      // Verify the cut is actually callable through the diamond
      const test1ViaDiamond = await ethers.getContractAt('Test1Facet', diamondAddress)
      await expect(test1ViaDiamond.test1Func1()).to.not.be.reverted
    })
  })
})
