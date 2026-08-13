// VoxGovernanceFacet tests using Hardhat + Mocha/Chai
// Assumptions:
// - Facet is deployed standalone for testing purposes.
// - Token storage and diamond cut paths are partially tested for require branches not dependent on token balances/totalSupply.
//
// Run with: npx hardhat test

const { expect } = require('chai')
const { ethers } = require('hardhat')
const { loadFixture, mine } = require('@nomicfoundation/hardhat-network-helpers')

const { deployDiamond } = require('../scripts/deploy.js')
const { getSelectors } = require('../scripts/libraries/diamond.js')

async function advanceBlocksForVoting(blocks = 15) {
  await mine(blocks);
}

describe('VoxGovernanceFacet', function () {
  const zeroAddress = ethers.ZeroAddress;

  // Test fixture for consistent setup
  async function deployGovernanceFixture() {
    const [owner, addr1, addr2] = await ethers.getSigners()
    
    const diamondAddress = await deployDiamond()
    const governanceFacet = await ethers.getContractAt('VoxGovernanceFacet', diamondAddress)
    const governanceLensFacet = await ethers.getContractAt('GovernanceLensFacet', diamondAddress)
    const tokenFacet = await ethers.getContractAt('VoxTokenFacet', diamondAddress)
    const ownershipFacet = await ethers.getContractAt('OwnershipFacet', diamondAddress)
    const diamondCutFacet = await ethers.getContractAt('DiamondCutFacet', diamondAddress)
    const voxFacet = await ethers.getContractAt('VoxFacet', diamondAddress)
    
    return {
      diamondAddress,
      governanceFacet,
      governanceLensFacet,
      tokenFacet,
      ownershipFacet,
      diamondCutFacet,
      voxFacet,
      owner,
      addr1,
      addr2
    }
  }

  // Helper function to create sample quota proposal
  function createSampleQuotaProposal() {
    return {
      proposedVoxClaimPercentage: 25,
      proposedViewerClaimPercentage: 55,
      proposedThirdParty1ClaimPercentage: 10,
      proposedThirdParty2ClaimPercentage: 5,
      proposedThirdParty3ClaimPercentage: 5,
      proposedThirdParty4ClaimPercentage: 0,
      proposedThirdParty5ClaimPercentage: 0,
      proposedThirdParty6ClaimPercentage: 0,
      proposedVoxAdminClaimPercentage: 10,
      proposedVoxAdminChangeQuorum: 51,
      proposedQuotaProposalQuorum: 25,
      proposedFacetProposalQuorum: 51,
      proposedStorageProviderPercentage: 5,
      proposedAdminApplicantFeeInPolWei: ethers.parseEther("1000"),
      proposedAdminVoteDeadlineInBlocks: 604800,
      // âœ… NEW: Proposal duration constraints
      proposedMinQuotaProposalDuration: 43200,      // ~1 day
      proposedMaxQuotaProposalDuration: 1296000,    // ~30 days
      proposedMinFacetProposalDuration: 43200,      // ~1 day
      proposedMaxFacetProposalDuration: 1296000     // ~30 days
    }
  }

  describe('Contract Owner Verification', function () {
    it('should verify LibDiamond contract owner is properly set', async function () {
      const { ownershipFacet, owner } = await loadFixture(deployGovernanceFixture)
      
      const contractOwner = await ownershipFacet.owner()
      
      expect(contractOwner).to.not.equal(ethers.ZeroAddress, "Contract owner is zero address")
      expect(contractOwner).to.equal(owner.address, "Contract owner does not match deployer")
    })
  })

  describe('Governance Storage and Initialization', function () {
    it('should return initial governance storage state', async function () {
      const { governanceFacet, governanceLensFacet } = await loadFixture(deployGovernanceFixture)
      
      const [
        votingStruct,
        proposedFacets,
        quotaProposal,
        currentQuotas,
        proposedAdminAddresses,
        adminVoteId,
        adminVoteDeadline
      ] = await governanceLensFacet.returnGovernanceStorage()
      
      expect(votingStruct.currentProposalId).to.equal(0)
      expect(votingStruct.isProposalActive).to.be.false
      expect(proposedFacets).to.have.length(0)
      expect(proposedAdminAddresses).to.have.length(0)
      expect(adminVoteId).to.equal(0)
    })

    it('should have reasonable default quotas', async function () {
      const { governanceFacet, governanceLensFacet } = await loadFixture(deployGovernanceFixture)
      
      const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
      
      expect(currentQuotas.voxClaimPercentage).to.be.a('bigint')
      expect(currentQuotas.QuotaProposalQuorum).to.be.a('bigint')
      expect(currentQuotas.FacetProposalQuorum).to.be.a('bigint')
    })
  })

  describe('Quota Proposal Management', function () {
    describe('Creating Quota Proposals', function () {
      it('should allow owner to create a quota proposal', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        const votingDuration = 605000
        
        await expect(
          governanceFacet.connect(owner).createProposal(
            0, // QuotaProposal
            quotaProposal,
            votingDuration,
            [],
            ethers.ZeroAddress,
            "0x"
          )
        ).to.not.be.reverted
        
        const [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.currentProposalId).to.equal(1)
        expect(votingStruct.isProposalActive).to.be.true
      })

      it('should prevent non-owners from creating quota proposals', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        
        await expect(
          governanceFacet.connect(addr1).createProposal(0, quotaProposal, 605000, [], ethers.ZeroAddress, "0x")
        ).to.be.revertedWith('LibDiamond: Must be contract owner')
      })

      it('should prevent creating proposals when one is already active', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        
        await governanceFacet.connect(owner).createProposal(0, quotaProposal, 605000, [], ethers.ZeroAddress, "0x")
        
        await expect(
          governanceFacet.connect(owner).createProposal(0, quotaProposal, 605000, [], ethers.ZeroAddress, "0x")
        ).to.be.revertedWith('Currently a proposal is already active')
      })

      it('should set correct voting deadline for quota proposals', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        const votingDuration = 605000
        
        const blockNumberBefore = await ethers.provider.getBlockNumber()
        
        await governanceFacet.connect(owner).createProposal(0, quotaProposal, votingDuration, [], ethers.ZeroAddress, "0x")
        
        const [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        
        expect(votingStruct[4]).to.be.approximately(
          blockNumberBefore + votingDuration,
          5
        )
      })

      it('should store all quota proposal parameters correctly', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        
        await governanceFacet.connect(owner).createProposal(0, quotaProposal, 605000, [], ethers.ZeroAddress, "0x")
        
        const [, , storedQuotaProposal] = await governanceLensFacet.returnGovernanceStorage()
        
        expect(storedQuotaProposal.proposedVoxClaimPercentage).to.equal(quotaProposal.proposedVoxClaimPercentage)
        expect(storedQuotaProposal.proposedQuotaProposalQuorum).to.equal(quotaProposal.proposedQuotaProposalQuorum)
        expect(storedQuotaProposal.proposedAdminApplicantFeeInPolWei).to.equal(quotaProposal.proposedAdminApplicantFeeInPolWei)
      })

      // âœ… NEW TEST: Validate duration constraints
      it('should enforce minimum quota proposal duration', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        const tooShortDuration = 43200 - 1 // 1 block less than minimum
        
        await expect(
          governanceFacet.connect(owner).createProposal(
            0, // QuotaProposal
            quotaProposal,
            tooShortDuration,
            [],
            ethers.ZeroAddress,
            "0x"
          )
        ).to.be.revertedWith('Quota proposal duration outside allowed range')
      })

      it('should enforce maximum quota proposal duration', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        const tooLongDuration = 1296000 + 1 // 1 block more than maximum
        
        await expect(
          governanceFacet.connect(owner).createProposal(
            0, // QuotaProposal
            quotaProposal,
            tooLongDuration,
            [],
            ethers.ZeroAddress,
            "0x"
          )
        ).to.be.revertedWith('Quota proposal duration outside allowed range')
      })

      it('should enforce minimum facet proposal duration', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        const tooShortDuration = 43200 - 1
        const sampleFacetCut = [{
          facetAddress: ethers.ZeroAddress,
          action: 2,
          functionSelectors: ['0x12345678']
        }]
        
        await expect(
          governanceFacet.connect(owner).createProposal(
            1, // FacetProposal
            quotaProposal,
            tooShortDuration,
            sampleFacetCut,
            ethers.ZeroAddress,
            "0x"
          )
        ).to.be.revertedWith('Facet proposal duration outside allowed range')
      })

      it('should enforce maximum facet proposal duration', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        const tooLongDuration = 1296000 + 1
        const sampleFacetCut = [{
          facetAddress: ethers.ZeroAddress,
          action: 2,
          functionSelectors: ['0x12345678']
        }]
        
        await expect(
          governanceFacet.connect(owner).createProposal(
            1, // FacetProposal
            quotaProposal,
            tooLongDuration,
            sampleFacetCut,
            ethers.ZeroAddress,
            "0x"
          )
        ).to.be.revertedWith('Facet proposal duration outside allowed range')
      })

      it('should accept valid duration within allowed range', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const quotaProposal = createSampleQuotaProposal()
        const validDuration = 605000 // Within 43200 to 1296000
        
        await expect(
          governanceFacet.connect(owner).createProposal(
            0, // QuotaProposal
            quotaProposal,
            validDuration,
            [],
            ethers.ZeroAddress,
            "0x"
          )
        ).to.not.be.reverted
      })
    })

    describe('Facet Proposal Management', function () {
      it('should allow owner to create a facet proposal', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const sampleFacetCut = [{
          facetAddress: ethers.ZeroAddress,
          action: 2,
          functionSelectors: ['0x12345678']
        }]
        
        await expect(
          governanceFacet.connect(owner).createProposal(
            1, // FacetProposal
            createSampleQuotaProposal(),
            605000,
            sampleFacetCut,
            ethers.ZeroAddress,
            "0x"
          )
        ).to.not.be.reverted
        
        const [votingStruct, proposedFacets] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.proposalType).to.equal(1)
        expect(proposedFacets).to.have.length(1)
      })

      it('should prevent non-owners from creating facet proposals', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await expect(
          governanceFacet.connect(addr1).createProposal(1, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        ).to.be.revertedWith('LibDiamond: Must be contract owner')
      })

      it('should handle multiple facet cuts in proposal', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const multipleFacetCuts = [
          { facetAddress: ethers.ZeroAddress, action: 2, functionSelectors: ['0x12345678'] },
          { facetAddress: ethers.ZeroAddress, action: 2, functionSelectors: ['0x87654321'] }
        ]
        
        await governanceFacet.connect(owner).createProposal(1, createSampleQuotaProposal(), 650000, multipleFacetCuts, ethers.ZeroAddress, "0x")
        
        const [, proposedFacets] = await governanceLensFacet.returnGovernanceStorage()
        expect(proposedFacets).to.have.length(2)
      })
    })

    describe('Proposal Revocation', function () {
      it('should allow owner to revoke active proposal', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        await expect(governanceFacet.connect(owner).revokeProposal()).to.not.be.reverted
        
        const [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.isProposalActive).to.be.false
      })

      it('should prevent non-owners from revoking proposals', async function () {
        const { governanceFacet, governanceLensFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        await expect(
          governanceFacet.connect(addr1).revokeProposal()
        ).to.be.revertedWith('LibDiamond: Must be contract owner')
      })

      it('should revert when trying to revoke non-existent proposal', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        await expect(
          governanceFacet.connect(owner).revokeProposal()
        ).to.be.revertedWith('No active proposal to revoke')
      })

      it('should prevent revoking after the voting deadline (item 4)', async function () {
        const { governanceFacet, owner } = await loadFixture(deployGovernanceFixture)

        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        await advanceBlocksForVoting(605000 + 1)

        // After the deadline the outcome belongs to token holders; revoke is closed.
        await expect(
          governanceFacet.connect(owner).revokeProposal()
        ).to.be.revertedWith('Voting ended: resolve via ratifyUpgrade')
      })
    })
  })

  describe('Bootstrap latch (item 2)', function () {
    async function deployFreshTest1() {
      const Test1Facet = await ethers.getContractFactory('Test1Facet')
      const test1 = await Test1Facet.deploy()
      await test1.waitForDeployment()
      const test1Address = await test1.getAddress()
      const selectors = getSelectors(test1).remove(['supportsInterface(bytes4)'])
      return { test1Address, selectors }
    }

    it('owner direct cut succeeds during bootstrap and is loupe-visible', async function () {
      const { diamondCutFacet, diamondAddress, ownershipFacet, owner } = await loadFixture(deployGovernanceFixture)
      const loupe = await ethers.getContractAt('IDiamondLoupe', diamondAddress)

      expect(await ownershipFacet.isBootstrapFinalized()).to.be.false

      const { test1Address, selectors } = await deployFreshTest1()
      await expect(
        diamondCutFacet.connect(owner).diamondCut([{ facetAddress: test1Address, action: 0, functionSelectors: selectors }], ethers.ZeroAddress, '0x')
      ).to.not.be.reverted

      expect(await loupe.facetAddress(selectors[0])).to.equal(test1Address)
    })

    it('owner VOX transfer does NOT trip the latch (no gas added to transfers)', async function () {
      const { diamondCutFacet, tokenFacet, ownershipFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)

      expect(await ownershipFacet.isBootstrapFinalized()).to.be.false
      await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1'))
      // Transfers must not finalize bootstrap — only finalizeBootstrap() does.
      expect(await ownershipFacet.isBootstrapFinalized()).to.be.false

      // Direct owner cut still works while the window is open.
      const { test1Address, selectors } = await deployFreshTest1()
      await expect(
        diamondCutFacet.connect(owner).diamondCut([{ facetAddress: test1Address, action: 0, functionSelectors: selectors }], ethers.ZeroAddress, '0x')
      ).to.not.be.reverted
    })

    it('explicit finalizeBootstrap closes the backdoor; is owner-only and non-idempotent', async function () {
      const { diamondCutFacet, ownershipFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)

      await expect(ownershipFacet.connect(addr1).finalizeBootstrap()).to.be.revertedWith('LibDiamond: Must be contract owner')

      await expect(ownershipFacet.connect(owner).finalizeBootstrap()).to.emit(ownershipFacet, 'BootstrapFinalized')
      expect(await ownershipFacet.isBootstrapFinalized()).to.be.true
      await expect(ownershipFacet.connect(owner).finalizeBootstrap()).to.be.revertedWith('Bootstrap already finalized')

      const { test1Address, selectors } = await deployFreshTest1()
      await expect(
        diamondCutFacet.connect(owner).diamondCut([{ facetAddress: test1Address, action: 0, functionSelectors: selectors }], ethers.ZeroAddress, '0x')
      ).to.be.revertedWith('Bootstrap finalized: use governance')
    })

    it('governance FacetProposal still cuts AFTER the latch is finalized (bypasses the latch)', async function () {
      const { governanceFacet, ownershipFacet, tokenFacet, diamondAddress, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
      const loupe = await ethers.getContractAt('IDiamondLoupe', diamondAddress)

      const totalSupply = await tokenFacet.totalSupply()
      const voteAmount = totalSupply / 3n
      await tokenFacet.connect(owner).transfer(addr1.address, voteAmount)
      await tokenFacet.connect(owner).transfer(addr2.address, voteAmount)
      await ownershipFacet.connect(owner).finalizeBootstrap() // explicitly close the window
      expect(await ownershipFacet.isBootstrapFinalized()).to.be.true

      const { test1Address, selectors } = await deployFreshTest1()
      await advanceBlocksForVoting(15)

      await governanceFacet.connect(owner).createProposal(
        1, createSampleQuotaProposal(), 605000,
        [{ facetAddress: test1Address, action: 0, functionSelectors: selectors }],
        ethers.ZeroAddress, '0x'
      )
      await governanceFacet.connect(addr1).voteOnProposal(true)
      await governanceFacet.connect(addr2).voteOnProposal(true)
      await advanceBlocksForVoting(605000 + 1)

      await expect(governanceFacet.connect(addr1).ratifyUpgrade()).to.not.be.reverted
      expect(await loupe.facetAddress(selectors[0])).to.equal(test1Address)
    })
  })

  describe('Voting on Proposals', function () {
    describe('Voting Mechanics', function () {
      it('should allow token holders to vote on proposals', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        await expect(governanceFacet.connect(addr1).voteOnProposal(true)).to.not.be.reverted
        
        const [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))
      })

      it('should weight votes by token balance', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await tokenFacet.connect(owner).transfer(addr2.address, ethers.parseEther('2000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        await governanceFacet.connect(addr1).voteOnProposal(true)
        await governanceFacet.connect(addr2).voteOnProposal(true)
        
        const [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('3000'))
      })

      it('should prevent double voting on same proposal', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(addr1).voteOnProposal(true)
        await advanceBlocksForVoting(15)
        
        await expect(
          governanceFacet.connect(addr1).voteOnProposal(false)
        ).to.be.revertedWith('Already voted')
      })

      it('should prevent voting after deadline', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        await advanceBlocksForVoting(605000 + 1)
        
        await expect(
          governanceFacet.connect(addr1).voteOnProposal(true)
        ).to.be.revertedWith('Voting period over')
      })

      it('should handle both support and opposition votes', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await tokenFacet.connect(owner).transfer(addr2.address, ethers.parseEther('1500'))
        await advanceBlocksForVoting(15)

        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")

        await governanceFacet.connect(addr1).voteOnProposal(true)
        await governanceFacet.connect(addr2).voteOnProposal(false)
        
        const [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))
        expect(votingStruct.totalOpposeVotesForCurrentProposal).to.equal(ethers.parseEther('1500'))
      })

      it('should handle zero balance voters gracefully', async function () {
        const { governanceFacet, governanceLensFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        // âœ… FIX: Update error message to match contract
        await expect(governanceFacet.connect(addr1).voteOnProposal(true)).to.be.revertedWith('No voting power')
      })
    })

    describe('Vote Undo Functionality', function () {
      // âœ… FIX: undoVote is in TokenFacet, not GovernanceFacet
      it('should allow voters to undo their votes', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        await governanceFacet.connect(addr1).voteOnProposal(true)

                // Verify vote was recorded
        let [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))


        //create an additional address called addr2
        const [, , , addr2] = await ethers.getSigners()
        
        // Vote undo happens automatically during token transfer
        await expect(tokenFacet.connect(addr1).transfer(addr2.address, ethers.parseEther('500'))).to.not.be.reverted
        
        const [votingStruct2] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct2.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('500'))
      })

      it('should prevent undoing votes if not voted', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        // Transfer tokens but DON'T vote
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        // addr1 has NOT voted yet
        const [votingStructBefore] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStructBefore.totalSupportVotesForCurrentProposal).to.equal(0)
        expect(votingStructBefore.totalOpposeVotesForCurrentProposal).to.equal(0)
        
        const [, , , addr2] = await ethers.getSigners()
        
        // Transfer tokens without having voted - should not affect vote counts
        await tokenFacet.connect(addr1).transfer(addr2.address, ethers.parseEther('500'))
        
        // Verify vote counts remain at zero (no undo needed because no vote was cast)
        const [votingStructAfter] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStructAfter.totalSupportVotesForCurrentProposal).to.equal(0)
        expect(votingStructAfter.totalOpposeVotesForCurrentProposal).to.equal(0)
      })

   it('should prevent undoing votes if not voted', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        // Transfer tokens but DON'T vote
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        // addr1 has NOT voted yet
        const [votingStructBefore] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStructBefore.totalSupportVotesForCurrentProposal).to.equal(0)
        expect(votingStructBefore.totalOpposeVotesForCurrentProposal).to.equal(0)
        
        const [, , , addr2] = await ethers.getSigners()
        
        // Transfer tokens without having voted - should not affect vote counts
        await tokenFacet.connect(addr1).transfer(addr2.address, ethers.parseEther('500'))
        
        // Verify vote counts remain at zero (no undo needed because no vote was cast)
        const [votingStructAfter] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStructAfter.totalSupportVotesForCurrentProposal).to.equal(0)
        expect(votingStructAfter.totalOpposeVotesForCurrentProposal).to.equal(0)
      })

      it('should allow re-voting after undo via transfer', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        // First vote: Support
        await governanceFacet.connect(addr1).voteOnProposal(true)
        
        let [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))
        expect(votingStruct.totalOpposeVotesForCurrentProposal).to.equal(0)
        
        const [, , , addr2] = await ethers.getSigners()
        
        // Transfer ALL tokens - this undoes the vote completely
        await tokenFacet.connect(addr1).transfer(addr2.address, ethers.parseEther('1000'))
        
        // Verify vote was completely undone
        let [votingStruct2] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct2.totalSupportVotesForCurrentProposal).to.equal(0)
        
        // Transfer tokens back to addr1
        await tokenFacet.connect(addr2).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        // Now addr1 can vote again (different vote this time - oppose)
        await expect(governanceFacet.connect(addr1).voteOnProposal(false)).to.not.be.reverted
        
        // Verify new vote was recorded
        let [votingStruct6] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct6.totalSupportVotesForCurrentProposal).to.equal(0)
        expect(votingStruct6.totalOpposeVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))
      })

      it('should handle partial token transfers correctly for vote adjustments', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        await governanceFacet.connect(addr1).voteOnProposal(true)
        
        // Initial vote: 1000 tokens for support
        let [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))
        
        const [, , , addr2] = await ethers.getSigners()
        
        // Transfer 300 tokens (30% of holdings)
        await tokenFacet.connect(addr1).transfer(addr2.address, ethers.parseEther('300'))
        
        // Vote should be reduced to 700 (70% of original)
        let [votingStruct2] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct2.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('700'))
        
        // Transfer another 400 tokens
        await tokenFacet.connect(addr1).transfer(addr2.address, ethers.parseEther('400'))
        
        // Vote should now be 300 (remaining balance)
        let [votingStruct3] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct3.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('300'))
      })

      it('should maintain vote integrity across multiple transfers and re-votes', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , addr2, addr3] = await ethers.getSigners()
        
        // Setup: Give addr1 tokens
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('2000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        // addr1 votes with 2000 tokens
        await governanceFacet.connect(addr1).voteOnProposal(true)
        
        let [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('2000'))
        
        // Transfer half to addr2 (vote auto-adjusts to 1000)
        await tokenFacet.connect(addr1).transfer(addr2.address, ethers.parseEther('1000'))
        
        let [votingStruct2] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct2.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))
        
        // addr2 can now vote with their 1000 tokens
        await advanceBlocksForVoting(15)
        await governanceFacet.connect(addr2).voteOnProposal(false)
        
        let [votingStruct3] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct3.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))
        expect(votingStruct3.totalOpposeVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))
        
        // Transfer all tokens from addr2 to addr3 (undoes addr2's vote)
        await tokenFacet.connect(addr2).transfer(addr3.address, ethers.parseEther('1000'))
        
        let [votingStruct4] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct4.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('1000'))
        expect(votingStruct4.totalOpposeVotesForCurrentProposal).to.equal(0) // addr2's vote undone
        
        // addr3 votes support with their received tokens
        await advanceBlocksForVoting(15)
        await governanceFacet.connect(addr3).voteOnProposal(true)
        
        let [votingStruct5] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct5.totalSupportVotesForCurrentProposal).to.equal(ethers.parseEther('2000'))
        expect(votingStruct5.totalOpposeVotesForCurrentProposal).to.equal(0)
      })
    })
  })

  describe('Proposal Ratification', function () {
    describe('Quota Proposal Ratification', function () {
      it('should ratify quota proposal when quorum is met', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const totalSupply = await tokenFacet.totalSupply()
        const voteAmount = totalSupply / 3n

        await tokenFacet.connect(owner).transfer(addr1.address, voteAmount)
        await tokenFacet.connect(owner).transfer(addr2.address, voteAmount)
        await advanceBlocksForVoting(15)
        
        const quotaProposal = createSampleQuotaProposal()
        await governanceFacet.connect(owner).createProposal(0, quotaProposal, 605000, [], ethers.ZeroAddress, "0x")
        
        await governanceFacet.connect(addr1).voteOnProposal(true)
        await governanceFacet.connect(addr2).voteOnProposal(true)

        await advanceBlocksForVoting(605000 + 1)
        
        await expect(governanceFacet.connect(owner).ratifyUpgrade()).to.not.be.reverted
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        expect(currentQuotas.voxClaimPercentage).to.equal(quotaProposal.proposedVoxClaimPercentage)
      })

      it('should resolve (without applying) when quorum is not met', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)

        const [, , , beforeQuotas] = await governanceLensFacet.returnGovernanceStorage()

        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('100'))
        await advanceBlocksForVoting(15)

        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 650000, [], ethers.ZeroAddress, "0x")
        await governanceFacet.connect(addr1).voteOnProposal(true)

        await advanceBlocksForVoting(650000 + 1)

        // Item 5: under-quorum proposals resolve without reverting; item 6: quorum on FOR votes only.
        await expect(governanceFacet.connect(owner).ratifyUpgrade()).to.not.be.reverted

        const [votingStruct, , , afterQuotas] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.isProposalActive).to.be.false
        expect(afterQuotas.voxClaimPercentage).to.equal(beforeQuotas.voxClaimPercentage)
      })

      it('should prevent ratification before voting period ends', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        await expect(
          governanceFacet.connect(owner).ratifyUpgrade()
        ).to.be.revertedWith('Voting period has not ended yet')
      })

      it('should allow anyone (zero-balance non-owner) to ratify a passed proposal after the deadline', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)

        const totalSupply = await tokenFacet.totalSupply()
        const voteAmount = totalSupply / 3n
        await tokenFacet.connect(owner).transfer(addr1.address, voteAmount)
        await tokenFacet.connect(owner).transfer(addr2.address, voteAmount)
        await advanceBlocksForVoting(15)

        const quotaProposal = createSampleQuotaProposal()
        await governanceFacet.connect(owner).createProposal(0, quotaProposal, 605000, [], ethers.ZeroAddress, "0x")
        await governanceFacet.connect(addr1).voteOnProposal(true)
        await governanceFacet.connect(addr2).voteOnProposal(true)

        await advanceBlocksForVoting(605000 + 1)

        // Item 3: ratification is permissionless post-deadline. Use a fresh signer that
        // holds no VOX and is not the owner to prove no privilege is required.
        const signers = await ethers.getSigners()
        const stranger = signers[6]
        expect(await tokenFacet.balanceOf(stranger.address)).to.equal(0n)

        await expect(governanceFacet.connect(stranger).ratifyUpgrade()).to.not.be.reverted

        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        expect(currentQuotas.voxClaimPercentage).to.equal(quotaProposal.proposedVoxClaimPercentage)
      })

      it('should resolve (without applying) when the proposal is denied (oppose >= support)', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)

        const [, , , beforeQuotas] = await governanceLensFacet.returnGovernanceStorage()

        const totalSupply = await tokenFacet.totalSupply()
        const voteAmount = totalSupply / 3n

        await tokenFacet.connect(owner).transfer(addr1.address, voteAmount)
        await tokenFacet.connect(owner).transfer(addr2.address, voteAmount)
        await advanceBlocksForVoting(15)

        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")

        await governanceFacet.connect(addr1).voteOnProposal(true)
        await governanceFacet.connect(addr2).voteOnProposal(false)

        await advanceBlocksForVoting(605000 + 1)

        // Item 5: denied proposals resolve without reverting; parameters must stay unchanged.
        await expect(governanceFacet.connect(owner).ratifyUpgrade()).to.not.be.reverted

        const [votingStruct, , , afterQuotas] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.isProposalActive).to.be.false
        expect(afterQuotas.voxClaimPercentage).to.equal(beforeQuotas.voxClaimPercentage)
      })
    })

    describe('Facet Proposal Ratification', function () {
      it('should execute a real facet cut when a FacetProposal passes (loupe-proven)', async function () {
        const { governanceFacet, tokenFacet, diamondAddress, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        const loupe = await ethers.getContractAt('IDiamondLoupe', diamondAddress)

        // Fresh facet whose selectors are not yet on the diamond — a valid Add cut.
        const Test1Facet = await ethers.getContractFactory('Test1Facet')
        const test1 = await Test1Facet.deploy()
        await test1.waitForDeployment()
        const test1Address = await test1.getAddress()
        const selectors = getSelectors(test1).remove(['supportsInterface(bytes4)'])
        const facetCut = [{ facetAddress: test1Address, action: 0, functionSelectors: selectors }]

        const totalSupply = await tokenFacet.totalSupply()
        const voteAmount = totalSupply / 3n
        await tokenFacet.connect(owner).transfer(addr1.address, voteAmount)
        await tokenFacet.connect(owner).transfer(addr2.address, voteAmount)
        await advanceBlocksForVoting(15)

        await governanceFacet.connect(owner).createProposal(1, createSampleQuotaProposal(), 605000, facetCut, ethers.ZeroAddress, "0x")
        await governanceFacet.connect(addr1).voteOnProposal(true)
        await governanceFacet.connect(addr2).voteOnProposal(true)
        await advanceBlocksForVoting(605000 + 1)

        await expect(governanceFacet.connect(addr1).ratifyUpgrade()).to.not.be.reverted

        // Proof item 1 is fixed: the governance cut actually took effect.
        for (const sel of selectors) {
          expect(await loupe.facetAddress(sel)).to.equal(test1Address)
        }
      })

      it('should resolve a FacetProposal without cutting when it fails quorum', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, diamondAddress, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        const loupe = await ethers.getContractAt('IDiamondLoupe', diamondAddress)

        const Test1Facet = await ethers.getContractFactory('Test1Facet')
        const test1 = await Test1Facet.deploy()
        await test1.waitForDeployment()
        const test1Address = await test1.getAddress()
        const selectors = getSelectors(test1).remove(['supportsInterface(bytes4)'])
        const facetCut = [{ facetAddress: test1Address, action: 0, functionSelectors: selectors }]

        // Under-quorum FOR vote only.
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('100'))
        await advanceBlocksForVoting(15)

        await governanceFacet.connect(owner).createProposal(1, createSampleQuotaProposal(), 605000, facetCut, ethers.ZeroAddress, "0x")
        await governanceFacet.connect(addr1).voteOnProposal(true)
        await advanceBlocksForVoting(605000 + 1)

        await expect(governanceFacet.connect(addr1).ratifyUpgrade()).to.not.be.reverted

        // No cut applied: the selector still resolves to nothing.
        expect(await loupe.facetAddress(selectors[0])).to.equal(ethers.ZeroAddress)
        const [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.isProposalActive).to.be.false
      })
    })
  })

  describe('Admin Management System', function () {
    describe('Admin Applications', function () {
      it('should allow users to apply as admin with correct fee', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const applicationFee = currentQuotas.adminApplicantFeeInPolWei
        
        await expect(
          governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmTest123", { value: applicationFee })
        ).to.not.be.reverted
        
        const [, , , , proposedAdminAddresses] = await governanceLensFacet.returnGovernanceStorage()
        expect(proposedAdminAddresses).to.have.length(2) // âœ… Now 2 (incumbent + addr1)
      })

      it('should reject applications with insufficient fee', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const insufficientFee = 5n
        
        await expect(
          governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmTest123", { value: insufficientFee })
        ).to.be.revertedWith('Insufficient POL sent to pay application fee')
      })

      it('should refund excess fee', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const requiredFee = currentQuotas.adminApplicantFeeInPolWei
        const excessFee = requiredFee + ethers.parseEther('100')
        
        const balanceBefore = await ethers.provider.getBalance(addr1.address)
        
        const tx = await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmTest123", { value: excessFee })
        const receipt = await tx.wait()
        const gasUsed = receipt.gasUsed * receipt.gasPrice
        
        const balanceAfter = await ethers.provider.getBalance(addr1.address)
        const expectedBalance = balanceBefore - requiredFee - gasUsed
        
        expect(balanceAfter).to.be.approximately(expectedBalance, ethers.parseEther('0.01'))
      })

      it('should prevent duplicate applications in same round', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmTest123", { value: fee })
        
        // Mine 2 blocks to clear flashLoanProtection cooldown (requires block.number > lastVoteBlock + 1)
        await ethers.provider.send("hardhat_mine", ["0x3"]);
        
        await expect(
          governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmTest456", { value: fee })
        ).to.be.revertedWith('You have already declared yourself an applicant for this round.')
      })

      // âœ… UPDATE: Multiple admin applications test
      it('should handle multiple admin applications', async function () {
        const { governanceFacet, governanceLensFacet, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , addr3] = await ethers.getSigners()
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmAddr1", { value: fee })
        await governanceFacet.connect(addr2).applyAsNewAdmin("ipfs://QmAddr2", { value: fee })
        await governanceFacet.connect(addr3).applyAsNewAdmin("ipfs://QmAddr3", { value: fee })
        
        const [, , , , proposedAdminAddresses] = await governanceLensFacet.returnGovernanceStorage()
        expect(proposedAdminAddresses).to.have.length(4) // âœ… Now 4 (incumbent + 3 applicants)
        expect(proposedAdminAddresses).to.include(addr1.address)
        expect(proposedAdminAddresses).to.include(addr2.address)
        expect(proposedAdminAddresses).to.include(addr3.address)
      })

      // âœ… NEW TEST: Storage ID functionality
      it('should store and retrieve admin applicant storage IDs', async function () {
        const { governanceFacet, governanceLensFacet, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        const storageId1 = "ipfs://QmTestAddr1Storage"
        const storageId2 = "ipfs://QmTestAddr2Storage"
        
        await governanceFacet.connect(addr1).applyAsNewAdmin(storageId1, { value: fee })
        await governanceFacet.connect(addr2).applyAsNewAdmin(storageId2, { value: fee })
        
        // Test getAdminApplicantStorageId
        const retrievedId1 = await governanceLensFacet.getAdminApplicantStorageId(addr1.address)
        expect(retrievedId1).to.equal(storageId1)
        
        const retrievedId2 = await governanceLensFacet.getAdminApplicantStorageId(addr2.address)
        expect(retrievedId2).to.equal(storageId2)
        
        // Test getAdminApplicantStorageId for self (getMyAdminApplicationStorageId not exposed on facet)
        const myStorageId = await governanceLensFacet.connect(addr1).getAdminApplicantStorageId(addr1.address)
        expect(myStorageId).to.equal(storageId1)
      })

      // âœ… NEW TEST: Storage IDs in returnGovernanceStorage
      it('should include storage IDs in returnGovernanceStorage', async function () {
        const { governanceFacet, governanceLensFacet, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmId1", { value: fee })
        await governanceFacet.connect(addr2).applyAsNewAdmin("ipfs://QmId2", { value: fee })
        
        const [, , , , proposedAdminAddresses, , , adminStorageIds] = await governanceLensFacet.returnGovernanceStorage()
        
        expect(adminStorageIds).to.have.length(proposedAdminAddresses.length)
        expect(adminStorageIds[0]).to.equal("INCUMBENT_ADMIN") // First is always incumbent
        expect(adminStorageIds).to.include("ipfs://QmId1")
        expect(adminStorageIds).to.include("ipfs://QmId2")
      })

      // âœ… NEW TEST: Storage IDs in getProposedOwnersAndVotes
      it('should include storage IDs in getProposedOwnersAndVotes', async function () {
        const { governanceFacet, governanceLensFacet, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmCandidate1", { value: fee })
        await governanceFacet.connect(addr2).applyAsNewAdmin("ipfs://QmCandidate2", { value: fee })
        
        // âœ… FIXED: Only 3 return values (removed againstVotes)
        const [proposedOwners, forVotes, storageIds] = await governanceLensFacet.getProposedOwnersAndVotes()
        
        expect(storageIds).to.have.length(proposedOwners.length)
        expect(storageIds[0]).to.equal("INCUMBENT_ADMIN") // First is always incumbent
        expect(storageIds).to.include("ipfs://QmCandidate1")
        expect(storageIds).to.include("ipfs://QmCandidate2")
      })

      // âœ… FIX: Correct destructuring - only 3 return values
      it('should automatically include incumbent admin as first candidate', async function () {
        const { governanceFacet, governanceLensFacet, ownershipFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const currentOwner = await ownershipFacet.owner()
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmFirstApplicant", { value: fee })
        
        // âœ… FIXED: Only 3 return values (removed againstVotes)
        const [proposedOwners, forVotes, storageIds] = await governanceLensFacet.getProposedOwnersAndVotes()
        
        expect(proposedOwners[0]).to.equal(currentOwner)
        expect(storageIds[0]).to.equal("INCUMBENT_ADMIN")
        expect(proposedOwners[1]).to.equal(addr1.address)
      })

      // âœ… NEW TEST: Prevent current owner from applying
      it('should prevent current owner from applying as new admin', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        await expect(
          governanceFacet.connect(owner).applyAsNewAdmin("ipfs://QmOwner", { value: fee })
        ).to.be.revertedWith('Current owner cannot apply as new admin')
      })
    })

    describe('Admin Application Revocation', function () {
      // âœ… UPDATE: Add storage ID parameter
      it('should allow applicants to revoke their application', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmTest", { value: currentQuotas.adminApplicantFeeInPolWei })
        
        await expect(governanceFacet.connect(addr1).revokeAdminApplication()).to.not.be.reverted
        
        const [, , , , proposedAdminAddresses] = await governanceLensFacet.returnGovernanceStorage()
        expect(proposedAdminAddresses).to.have.length(1) // âœ… Only incumbent remains
      })

      // âœ… FIX: Correct destructuring for returnGovernanceStorage
      it('should handle array reorganization correctly on revocation', async function () {
        const { governanceFacet, governanceLensFacet, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , addr3] = await ethers.getSigners()
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://Qm1", { value: fee })
        await governanceFacet.connect(addr2).applyAsNewAdmin("ipfs://Qm2", { value: fee })
        await governanceFacet.connect(addr3).applyAsNewAdmin("ipfs://Qm3", { value: fee })
        
        await governanceFacet.connect(addr2).revokeAdminApplication()
        
        // âœ… FIX: Properly destructure the return value
        const [, , , , proposedAdminAddresses] = await governanceLensFacet.returnGovernanceStorage()
        expect(proposedAdminAddresses).to.have.length(3) // âœ… Incumbent + 2 applicants
        expect(proposedAdminAddresses).to.include(addr1.address)
        expect(proposedAdminAddresses).to.include(addr3.address)
        expect(proposedAdminAddresses).to.not.include(addr2.address)
      })
    })

    describe('Admin Voting', function () {
      // âœ… FIX: Remove boolean parameter from voteForNewAdmin calls
      it('should allow voting for admin candidates', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr2.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmCandidate1", { value: currentQuotas.adminApplicantFeeInPolWei })
        
        // âœ… FIXED: Removed boolean parameter
        await expect(
          governanceFacet.connect(addr2).voteForNewAdmin(addr1.address)
        ).to.not.be.reverted
        
        const [proposedOwners, forVotes] = await governanceLensFacet.getProposedOwnersAndVotes()
        // âœ… FIX: Check index 1 (addr1 is second, after incumbent)
        expect(forVotes[1]).to.equal(ethers.parseEther('1000'))
      })

      it('should prevent voting for non-candidates', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        
        // âœ… FIXED: Removed boolean parameter
        await expect(
          governanceFacet.connect(addr1).voteForNewAdmin(addr2.address)
        ).to.be.reverted
      })

      // âœ… FIX: Remove boolean parameter
      it('should prevent double voting for same candidate', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr2.address, ethers.parseEther('1000'))
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmCandidate1", { value: currentQuotas.adminApplicantFeeInPolWei })
        await advanceBlocksForVoting(15)

        // âœ… FIXED: Removed boolean parameter
        await governanceFacet.connect(addr2).voteForNewAdmin(addr1.address)
        await advanceBlocksForVoting(15)
        
        // âœ… FIXED: Updated error message and removed boolean
        await expect(
          governanceFacet.connect(addr2).voteForNewAdmin(addr1.address)
        ).to.be.revertedWith('Already voted for this candidate in the current round')
      })

      // âœ… FIX: Update test - no opposition votes anymore
      it('should only allow support votes for admin candidates', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , addr3] = await ethers.getSigners()
        
        await tokenFacet.connect(owner).transfer(addr2.address, ethers.parseEther('1000'))
        await tokenFacet.connect(owner).transfer(addr3.address, ethers.parseEther('1500'))
        await advanceBlocksForVoting(15)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmCandidate1", { value: currentQuotas.adminApplicantFeeInPolWei })
        
        // âœ… FIXED: Only support votes (removed boolean parameter)
        await governanceFacet.connect(addr2).voteForNewAdmin(addr1.address)
        await governanceFacet.connect(addr3).voteForNewAdmin(addr1.address)
        
        const [, forVotes] = await governanceLensFacet.getProposedOwnersAndVotes()
        // âœ… FIX: Check index 1 (addr1 is second, after incumbent)
        expect(forVotes[1]).to.equal(ethers.parseEther('2500')) // Both votes added together
      })
    })

    describe('Admin Ratification', function () {
      // âœ… FIX: Remove boolean parameter
      it('should ratify admin with highest net votes meeting quorum', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, ownershipFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const totalSupply = await tokenFacet.totalSupply()
        const quorumPercentage = currentQuotas.voxAdminChangeQuorum
        const quorumAmount = (totalSupply * BigInt(quorumPercentage)) / 100n
        const votingAmount = quorumAmount + ethers.parseEther('1000')
        
        await tokenFacet.connect(owner).transfer(addr2.address, votingAmount)
        await advanceBlocksForVoting(15)
        
        const adminFee = currentQuotas.adminApplicantFeeInPolWei
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmCandidate1", { value: adminFee })

        // âœ… FIXED: Removed boolean parameter
        await governanceFacet.connect(addr2).voteForNewAdmin(addr1.address)

        const [, , , , , , adminVoteDeadline] = await governanceLensFacet.returnGovernanceStorage()
        const currentBlock = await ethers.provider.getBlockNumber()
        const blocksToAdvance = Number(adminVoteDeadline) - currentBlock + 1

        await advanceBlocksForVoting(blocksToAdvance)
        
        const tx = await governanceFacet.ratifyNewAdmin()
        await tx.wait()
        
        const ownerAfter = await ownershipFacet.owner()
        
        expect(ownerAfter).to.equal(addr1.address)
      })

      // âœ… FIX: Add storage ID parameter
      it('should prevent ratification when no candidates meet quorum', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmCandidate1", { value: currentQuotas.adminApplicantFeeInPolWei })
        
        //advance blocks to pass admin vote deadline
        const [, , , , , , adminVoteDeadline] = await governanceLensFacet.returnGovernanceStorage()
        const currentBlock = await ethers.provider.getBlockNumber()
        const blocksToAdvance = Number(adminVoteDeadline) - currentBlock + 1
        await advanceBlocksForVoting(blocksToAdvance)
        await expect(
          governanceFacet.ratifyNewAdmin()
        ).to.be.revertedWith('No candidates met the quorum')
      })
    })
  })

  describe('View Functions and Data Retrieval', function () {
    describe('getProposedOwnersAndVotes()', function () {
      it('should return empty arrays when no admin candidates', async function () {
        const { governanceFacet, governanceLensFacet } = await loadFixture(deployGovernanceFixture)
        
        const [proposedOwners, forVotes] = await governanceLensFacet.getProposedOwnersAndVotes()
        
        expect(proposedOwners).to.have.length(0)
        expect(forVotes).to.have.length(0)
      })

      // âœ… FIX: Remove boolean parameter and update expectations
      it('should return correct data for multiple candidates', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , addr3] = await ethers.getSigners()
        
        await tokenFacet.connect(owner).transfer(addr3.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmCandidate1", { value: fee })
        await governanceFacet.connect(addr2).applyAsNewAdmin("ipfs://QmCandidate2", { value: fee })
        
        // âœ… FIXED: Removed boolean parameter
        await governanceFacet.connect(addr3).voteForNewAdmin(addr1.address)
        
        const [proposedOwners, forVotes, storageIds] = await governanceLensFacet.getProposedOwnersAndVotes()
        
        // âœ… FIX: Now 3 candidates (incumbent + addr1 + addr2)
        expect(proposedOwners).to.have.length(3)
        expect(forVotes).to.have.length(3)
        expect(storageIds).to.have.length(3)
        // âœ… FIX: addr1 is at index 1 (after incumbent)
        expect(forVotes[1]).to.equal(ethers.parseEther('1000'))
        expect(forVotes[2]).to.equal(0) // addr2 has no votes
        
        // âœ… NEW: Check storage IDs
        expect(storageIds[0]).to.equal("INCUMBENT_ADMIN")
        expect(storageIds[1]).to.equal("ipfs://QmCandidate1")
        expect(storageIds[2]).to.equal("ipfs://QmCandidate2")
      })
    })

    describe('returnGovernanceStorage()', function () {
      it('should return comprehensive governance state', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        const [
          votingStruct,
          proposedFacets,
          quotaProposal,
          currentQuotas,
          proposedAdminAddresses,
          adminVoteId,
          adminVoteDeadline
        ] = await governanceLensFacet.returnGovernanceStorage()
        
        expect(votingStruct[0]).to.equal(1)
        expect(votingStruct[1]).to.be.true
        expect(votingStruct[2]).to.equal(0)
        expect(votingStruct[4]).to.be.greaterThan(0)
      })

      it('should be a view function with no gas cost', async function () {
        const { governanceFacet, governanceLensFacet } = await loadFixture(deployGovernanceFixture)
        
        const result = await governanceLensFacet.returnGovernanceStorage.staticCall()
        expect(result).to.be.an('array')
      })
    })
  })

  describe('Edge Cases and Error Handling', function () {
    describe('State Consistency', function () {
      it('should maintain consistent state across complex operations', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(20)
        
        await governanceFacet.connect(addr1).voteOnProposal(true)
        await governanceFacet.connect(owner).revokeProposal()
        
        const [votingStruct] = await governanceLensFacet.returnGovernanceStorage()
        expect(votingStruct.currentProposalId).to.equal(1)
        expect(votingStruct.isProposalActive).to.be.false
      })

      // âœ… FIX: Add storage ID parameter
      it('should handle admin round transitions correctly', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://QmCandidate1", { value: currentQuotas.adminApplicantFeeInPolWei })
        
        const [, , , , proposedAdminAddresses, adminVoteId] = await governanceLensFacet.returnGovernanceStorage()
        // âœ… FIX: Now 2 (incumbent + addr1)
        expect(proposedAdminAddresses).to.have.length(2)
        expect(adminVoteId).to.equal(0)

        //advance blocks to pass admin vote deadline
        const [, , , , , , adminVoteDeadline] = await governanceLensFacet.returnGovernanceStorage()
        const currentBlock = await ethers.provider.getBlockNumber()
        const blocksToAdvance = Number(adminVoteDeadline) - currentBlock + 1
        await advanceBlocksForVoting(blocksToAdvance)
        
        await expect(governanceFacet.ratifyNewAdmin()).to.be.revertedWith('No candidates met the quorum')
      })
    })

    describe('Gas Efficiency', function () {
      it('should have reasonable gas costs for common operations', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const gasEstimate = await governanceFacet.connect(owner).createProposal.estimateGas(
          0,
          createSampleQuotaProposal(),
          605000,
          [],
          ethers.ZeroAddress,
          "0x"
        )
        
        expect(gasEstimate).to.be.lessThan(700000)
      })

      // âœ… FIX: Add storage ID parameter and declare addr3
      it('should scale reasonably with multiple admin candidates', async function () {
        const { governanceFacet, governanceLensFacet, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const [, , , addr3] = await ethers.getSigners()
        
        const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
        const fee = currentQuotas.adminApplicantFeeInPolWei
        
        const gas1 = await governanceFacet.connect(addr1).applyAsNewAdmin.estimateGas("ipfs://Qm1", { value: fee })

        await governanceFacet.connect(addr1).applyAsNewAdmin("ipfs://Qm1", { value: fee })
        const gas2 = await governanceFacet.connect(addr2).applyAsNewAdmin.estimateGas("ipfs://Qm2", { value: fee })

        await governanceFacet.connect(addr2).applyAsNewAdmin("ipfs://Qm2", { value: fee })
        const gas3 = await governanceFacet.connect(addr3).applyAsNewAdmin.estimateGas("ipfs://Qm3", { value: fee })

        expect(gas2).to.be.lessThan(gas1 * 2n)
        expect(gas3).to.be.lessThan(gas1 * 3n)
      })
    })
  })

  describe('Integration with Diamond Architecture', function () {
    it('should work correctly within diamond proxy', async function () {
      const { governanceFacet, governanceLensFacet, diamondAddress } = await loadFixture(deployGovernanceFixture)
      
      expect(await governanceFacet.getAddress()).to.equal(diamondAddress)
    })

    it('should maintain state persistence across calls', async function () {
      const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
      
      await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
      
      const [votingStruct1] = await governanceLensFacet.returnGovernanceStorage()
      const [votingStruct2] = await governanceLensFacet.returnGovernanceStorage()
      
      expect(votingStruct1.currentProposalId).to.equal(votingStruct2.currentProposalId)
    })

    it('should handle ownership integration correctly', async function () {
      const { governanceFacet, governanceLensFacet, ownershipFacet, owner } = await loadFixture(deployGovernanceFixture)
      
      const currentOwner = await ownershipFacet.owner()
      expect(currentOwner).to.equal(owner.address)
      
      await expect(
        governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
      ).to.not.be.reverted
    })
  })

  describe('User Ban Management', function () {
    it('should allow owner to ban a user', async function () {
      const { governanceFacet, governanceLensFacet, voxFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
      
      // Verify user is not banned initially
      const isBannedBefore = await voxFacet.isUserBannedFromPlatform(addr1.address)
      expect(isBannedBefore).to.be.false
      
      // Ban the user
      await expect(governanceFacet.connect(owner).banUserFromPlatform(addr1.address))
        .to.emit(governanceFacet, 'UserBanned')
        .withArgs(addr1.address, await ethers.provider.getBlockNumber() + 1)
      
      // Verify user is now banned
      const isBannedAfter = await voxFacet.isUserBannedFromPlatform(addr1.address)
      expect(isBannedAfter).to.be.true
      
      // Check ban block number is set
      const banBlock = await governanceLensFacet.getUserPlatformBanBlockNumber(addr1.address)
      expect(banBlock).to.be.gt(0)
    })

    it('should allow owner to unban a user', async function () {
      const { governanceFacet, governanceLensFacet, voxFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
      
      // Ban user first
      await governanceFacet.connect(owner).banUserFromPlatform(addr1.address)
      expect(await voxFacet.isUserBannedFromPlatform(addr1.address)).to.be.true
      
      // Unban the user
      await expect(governanceFacet.connect(owner).unbanUserFromPlatform(addr1.address))
        .to.emit(governanceFacet, 'UserUnbanned')
        .withArgs(addr1.address, await ethers.provider.getBlockNumber() + 1)
      
      // Verify user is no longer banned
      const isBanned = await voxFacet.isUserBannedFromPlatform(addr1.address)
      expect(isBanned).to.be.false
      
      // Ban block number should still be recorded for history
      const banBlock = await governanceLensFacet.getUserPlatformBanBlockNumber(addr1.address)
      expect(banBlock).to.be.gt(0)
    })

    it('should prevent non-owner from banning users', async function () {
      const { governanceFacet, governanceLensFacet, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
      
      await expect(
        governanceFacet.connect(addr1).banUserFromPlatform(addr2.address)
      ).to.be.revertedWith('VOXA')
    })

    it('should prevent non-owner from unbanning users', async function () {
      const { governanceFacet, governanceLensFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
      
      // Ban user as owner
      await governanceFacet.connect(owner).banUserFromPlatform(addr2.address)
      
      // Try to unban as non-owner
      await expect(
        governanceFacet.connect(addr1).unbanUserFromPlatform(addr2.address)
      ).to.be.revertedWith('VOXA')
    })

    it('should prevent banning zero address', async function () {
      const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
      
      await expect(
        governanceFacet.connect(owner).banUserFromPlatform(ethers.ZeroAddress)
      ).to.be.revertedWith('Z')
    })

    it('should prevent banning already banned user', async function () {
      const { governanceFacet, governanceLensFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
      
      await governanceFacet.connect(owner).banUserFromPlatform(addr1.address)
      
      await expect(
        governanceFacet.connect(owner).banUserFromPlatform(addr1.address)
      ).to.be.revertedWith('User is already banned')
    })

    it('should prevent unbanning non-banned user', async function () {
      const { governanceFacet, governanceLensFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
      
      await expect(
        governanceFacet.connect(owner).unbanUserFromPlatform(addr1.address)
      ).to.be.revertedWith('User is not banned')
    })

    it('should return correct ban block number', async function () {
      const { governanceFacet, governanceLensFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
      
      // No ban initially
      expect(await governanceLensFacet.getUserPlatformBanBlockNumber(addr1.address)).to.equal(0)
      
      // Ban user
      const tx = await governanceFacet.connect(owner).banUserFromPlatform(addr1.address)
      const receipt = await tx.wait()
      
      // Check ban block number
      const banBlock = await governanceLensFacet.getUserPlatformBanBlockNumber(addr1.address)
      expect(banBlock).to.equal(receipt.blockNumber)
    })

    it('should maintain ban history after unban', async function () {
      const { governanceFacet, governanceLensFacet, voxFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
      
      // Ban and record block number
      const banTx = await governanceFacet.connect(owner).banUserFromPlatform(addr1.address)
      const banReceipt = await banTx.wait()
      const banBlock = banReceipt.blockNumber
      
      // Unban
      await governanceFacet.connect(owner).unbanUserFromPlatform(addr1.address)
      
      // Ban block number should still be recorded
      expect(await governanceLensFacet.getUserPlatformBanBlockNumber(addr1.address)).to.equal(banBlock)
      
      // But user should not be banned
      expect(await voxFacet.isUserBannedFromPlatform(addr1.address)).to.be.false
    })
  })

  describe('Additional View Functions', function () {
    describe('getCurrentGovernanceState()', function () {
      it('should return complete governance state', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        const [
          isProposalActive,
          proposalId,
          proposalType,
          votingDeadline,
          totalSupport,
          totalOppose
        ] = await governanceLensFacet.getCurrentGovernanceState()
        
        expect(isProposalActive).to.be.false
        expect(proposalId).to.equal(0)
        expect(totalSupport).to.equal(0)
        expect(totalOppose).to.equal(0)
      })

      it('should reflect active proposal state', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        const [isProposalActive, proposalId, proposalType] = await governanceLensFacet.getCurrentGovernanceState()
        
        expect(isProposalActive).to.be.true
        expect(proposalType).to.equal(0) // QuotaProposal
        expect(proposalId).to.equal(1)
      })
    })

    describe('getAdminElectionState()', function () {
      it('should return empty state initially', async function () {
        const { governanceFacet, governanceLensFacet } = await loadFixture(deployGovernanceFixture)
        
        const [candidates, balances, voteId, deadline, candidateCount] = await governanceLensFacet.getAdminElectionState()
        
        expect(candidates).to.have.length(0)
        expect(voteId).to.equal(0)
        expect(candidateCount).to.equal(0)
      })

      it('should return correct state with candidates', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        // Transfer tokens for fees
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('2000'))
        await advanceBlocksForVoting(15)
        
        // Apply as admin candidates
        const fee = ethers.parseEther('1000')
        await governanceFacet.connect(addr1).applyAsNewAdmin('storage-id-1', { value: fee })
        await governanceFacet.connect(addr2).applyAsNewAdmin('storage-id-2', { value: fee })
        
        const [candidates, balances, voteId, deadline, candidateCount] = await governanceLensFacet.getAdminElectionState()
        
        expect(candidateCount).to.equal(3) // incumbent + 2 applicants
        expect(candidates).to.have.length(3)
        expect(voteId).to.equal(0)
        expect(deadline).to.be.gt(0)
      })
    })

    describe('getAllCurrentQuotas()', function () {
      it('should return all quota settings', async function () {
        const { governanceFacet, governanceLensFacet } = await loadFixture(deployGovernanceFixture)
        
        const quotas = await governanceLensFacet.getAllCurrentQuotas()
        
        expect(quotas.voxClaimPercentage).to.be.a('bigint')
        expect(quotas.viewerClaimPercentage).to.be.a('bigint')
        expect(quotas.thirdParty1ClaimPercentage).to.be.a('bigint')
        expect(quotas.voxAdminChangeQuorum).to.be.a('bigint')
        expect(quotas.QuotaProposalQuorum).to.be.a('bigint')
        expect(quotas.FacetProposalQuorum).to.be.a('bigint')
        expect(quotas.adminApplicantFeeInPolWei).to.be.a('bigint')
        expect(quotas.minQuotaProposalDuration).to.be.a('bigint')
        expect(quotas.maxQuotaProposalDuration).to.be.a('bigint')
      })

      it('should reflect updated quotas after ratification', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        // Transfer tokens for voting - need >51% of 21M for quorum
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('11000000'))
        await advanceBlocksForVoting(15)
        
        // Create proposal with new quota values
        const quotaProposal = createSampleQuotaProposal()
        quotaProposal.proposedVoxClaimPercentage = 30
        quotaProposal.proposedViewerClaimPercentage = 50
        
        await governanceFacet.connect(owner).createProposal(0, quotaProposal, 605000, [], ethers.ZeroAddress, "0x")
        
        // Vote and ratify
        await governanceFacet.connect(addr1).voteOnProposal(true)
        await advanceBlocksForVoting(605000 + 1)
        await governanceFacet.connect(owner).ratifyUpgrade()
        
        // Check updated quotas
        const newQuotas = await governanceLensFacet.getAllCurrentQuotas()
        expect(newQuotas.voxClaimPercentage).to.equal(30)
        expect(newQuotas.viewerClaimPercentage).to.equal(50)
      })
    })

    describe('getProposalState()', function () {
      it('should return NoProposal state when no proposal exists', async function () {
        const { governanceFacet, governanceLensFacet } = await loadFixture(deployGovernanceFixture)
        
        const [state, canRatify] = await governanceLensFacet.getProposalState()
        
        expect(state).to.equal(4) // NoProposal
        expect(canRatify).to.be.false
      })

      it('should return Active state during voting period', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        const [state, canRatify] = await governanceLensFacet.getProposalState()
        
        expect(state).to.equal(0) // Active
        expect(canRatify).to.be.false
      })

      it('should return Succeeded state when quorum met', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        // Transfer >51% of 21M tokens to meet quorum (need >10.71M)
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('11000000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        await governanceFacet.connect(addr1).voteOnProposal(true)
        
        await advanceBlocksForVoting(605000 + 1)
        
        const [state, canRatify] = await governanceLensFacet.getProposalState()
        
        expect(state).to.equal(1) // Succeeded/Passed
        expect(canRatify).to.be.true
      })

      it('should return Defeated state when quorum not met', async function () {
        const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        await advanceBlocksForVoting(605000 + 1)
        
        const [state, canRatify] = await governanceLensFacet.getProposalState()
        
        expect(state).to.equal(2) // Defeated
        expect(canRatify).to.be.false // Defeated proposals cannot be ratified
      })
    })

    describe('canVoteOnProposal()', function () {
      it('should return false when no proposal active', async function () {
        const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployGovernanceFixture)
        
        const canVote = await governanceLensFacet.canVoteOnProposal(addr1.address)
        expect(canVote).to.be.false
      })

      it('should return true for eligible voters', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        const canVote = await governanceLensFacet.canVoteOnProposal(addr1.address)
        expect(canVote).to.be.true
      })

      it('should return false for voters with zero balance', async function () {
        const { governanceFacet, governanceLensFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        const canVote = await governanceLensFacet.canVoteOnProposal(addr1.address)
        expect(canVote).to.be.false
      })

      it('should return false after voting deadline', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        await governanceFacet.connect(owner).createProposal(0, createSampleQuotaProposal(), 605000, [], ethers.ZeroAddress, "0x")
        
        await advanceBlocksForVoting(605000 + 1)
        
        const canVote = await governanceLensFacet.canVoteOnProposal(addr1.address)
        expect(canVote).to.be.false
      })
    })

    describe('canVoteForAdmin()', function () {
      it('should return false when no admin election active', async function () {
        const { governanceFacet, governanceLensFacet, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        const canVote = await governanceLensFacet.canVoteForAdmin(addr1.address, addr2.address)
        expect(canVote).to.be.false
      })

      it('should return true for eligible admin voters', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('2000'))
        await advanceBlocksForVoting(15)
        
        const fee = ethers.parseEther('1000')
        await governanceFacet.connect(addr2).applyAsNewAdmin('storage-id', { value: fee })
        
        const canVote = await governanceLensFacet.canVoteForAdmin(addr1.address, addr2.address)
        expect(canVote).to.be.true
      })

      it('should return false for non-candidates', async function () {
        const { governanceFacet, governanceLensFacet, tokenFacet, owner, addr1, addr2 } = await loadFixture(deployGovernanceFixture)
        
        await tokenFacet.connect(owner).transfer(addr1.address, ethers.parseEther('1000'))
        await advanceBlocksForVoting(15)
        
        const canVote = await governanceLensFacet.canVoteForAdmin(addr1.address, addr2.address)
        expect(canVote).to.be.false
      })
    })
  })
})