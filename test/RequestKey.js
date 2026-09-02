// RequestKey feature tests: on-chain requestKey that rotates atomically with ownership.
//
// Covers VoxRequestKeyFacet (setRequestKey + validation), OwnershipFacet 1-arg/2-arg
// transferOwnership, GovernanceLensFacet.returnRequestKey, and the VoxGovernanceFacet
// admin-election rotation (including the incumbent-keeps-key guard).
//
// Run with: npx hardhat test test/RequestKey.js

const { expect } = require('chai')
const { ethers } = require('hardhat')
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers')

const { deployDiamond } = require('../scripts/deploy.js')

describe('RequestKey', function () {
  // Fresh, valid requestKey (nonzero and, with overwhelming probability, distinct from the owner,
  // the current requestKey and the signing address).
  const freshKey = () => ethers.Wallet.createRandom().address

  async function deployRequestKeyFixture() {
    const [owner, addr1, addr2, addr3] = await ethers.getSigners()

    const diamondAddress = await deployDiamond()

    const requestKeyFacet = await ethers.getContractAt('VoxRequestKeyFacet', diamondAddress)
    const governanceLensFacet = await ethers.getContractAt('GovernanceLensFacet', diamondAddress)
    const governanceFacet = await ethers.getContractAt('VoxGovernanceFacet', diamondAddress)
    const ownershipFacet = await ethers.getContractAt('OwnershipFacet', diamondAddress)
    const tokenFacet = await ethers.getContractAt('VoxTokenFacet', diamondAddress)

    const signingAddress = await governanceLensFacet.returnChapterSignerAddress()

    return {
      diamondAddress,
      requestKeyFacet,
      governanceLensFacet,
      governanceFacet,
      ownershipFacet,
      tokenFacet,
      signingAddress,
      owner,
      addr1,
      addr2,
      addr3
    }
  }

  describe('Deployment seeding', function () {
    it('seeds a nonzero requestKey equal to REQUEST_KEY_ADDRESS_FE', async function () {
      const { governanceLensFacet } = await loadFixture(deployRequestKeyFixture)

      const requestKey = await governanceLensFacet.returnRequestKey()
      expect(requestKey).to.not.equal(ethers.ZeroAddress)
      expect(requestKey).to.equal(ethers.getAddress(process.env.REQUEST_KEY_ADDRESS_FE))
    })

    it('seeds a requestKey distinct from the signing address', async function () {
      const { governanceLensFacet, signingAddress } = await loadFixture(deployRequestKeyFixture)
      expect(await governanceLensFacet.returnRequestKey()).to.not.equal(signingAddress)
    })
  })

  describe('setRequestKey (owner-only, immediate)', function () {
    it('lets the owner rotate the key and emits RequestKeyUpdated(prev, new, owner)', async function () {
      const { requestKeyFacet, governanceLensFacet, owner } = await loadFixture(deployRequestKeyFixture)

      const previous = await governanceLensFacet.returnRequestKey()
      const next = freshKey()

      await expect(requestKeyFacet.connect(owner).setRequestKey(next))
        .to.emit(requestKeyFacet, 'RequestKeyUpdated')
        .withArgs(previous, next, owner.address)

      expect(await governanceLensFacet.returnRequestKey()).to.equal(next)
    })

    it('reverts for a non-owner caller', async function () {
      const { requestKeyFacet, addr1 } = await loadFixture(deployRequestKeyFixture)
      await expect(
        requestKeyFacet.connect(addr1).setRequestKey(freshKey())
      ).to.be.revertedWith('LibDiamond: Must be contract owner')
    })

    it('reverts on the zero address', async function () {
      const { requestKeyFacet, owner } = await loadFixture(deployRequestKeyFixture)
      await expect(
        requestKeyFacet.connect(owner).setRequestKey(ethers.ZeroAddress)
      ).to.be.revertedWith('RequestKey: zero')
    })

    it('reverts when the new key equals the owner', async function () {
      const { requestKeyFacet, owner } = await loadFixture(deployRequestKeyFixture)
      await expect(
        requestKeyFacet.connect(owner).setRequestKey(owner.address)
      ).to.be.revertedWith('RequestKey: equals owner')
    })

    it('reverts when the new key equals the current requestKey (must actually change)', async function () {
      const { requestKeyFacet, governanceLensFacet, owner } = await loadFixture(deployRequestKeyFixture)
      const current = await governanceLensFacet.returnRequestKey()
      await expect(
        requestKeyFacet.connect(owner).setRequestKey(current)
      ).to.be.revertedWith('RequestKey: unchanged')
    })

    it('reverts when the new key equals the signing address (separation of duties)', async function () {
      const { requestKeyFacet, signingAddress, owner } = await loadFixture(deployRequestKeyFixture)
      await expect(
        requestKeyFacet.connect(owner).setRequestKey(signingAddress)
      ).to.be.revertedWith('RequestKey: equals signer')
    })
  })

  describe('setChapterSignerAddress (symmetric separation of duties)', function () {
    it('rejects a chapter-signer address equal to the current requestKey', async function () {
      const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployRequestKeyFixture)
      const requestKey = await governanceLensFacet.returnRequestKey()
      await expect(
        governanceFacet.connect(owner).setChapterSignerAddress(requestKey)
      ).to.be.revertedWith('ChapterSigner: equals requestKey')
    })

    it('allows the owner to set a chapter-signer address distinct from the requestKey', async function () {
      const { governanceFacet, governanceLensFacet, owner } = await loadFixture(deployRequestKeyFixture)
      const next = freshKey()
      await expect(governanceFacet.connect(owner).setChapterSignerAddress(next))
        .to.emit(governanceFacet, 'ChapterSignerAddressUpdated')
        .withArgs(next)
      expect(await governanceLensFacet.returnChapterSignerAddress()).to.equal(next)
    })
  })

  describe('transferOwnership', function () {
    it('reverts the disabled 1-arg form', async function () {
      const { ownershipFacet, owner, addr1 } = await loadFixture(deployRequestKeyFixture)
      await expect(
        ownershipFacet.connect(owner)['transferOwnership(address)'](addr1.address)
      ).to.be.revertedWith('Use transferOwnership(address,address)')
    })

    it('atomically transfers ownership and rotates the requestKey', async function () {
      const { ownershipFacet, governanceLensFacet, requestKeyFacet, owner, addr1 } =
        await loadFixture(deployRequestKeyFixture)

      const previousKey = await governanceLensFacet.returnRequestKey()
      const newKey = freshKey()

      const tx = await ownershipFacet.connect(owner)['transferOwnership(address,address)'](addr1.address, newKey)
      await expect(tx)
        .to.emit(ownershipFacet, 'OwnershipTransferred')
        .withArgs(owner.address, addr1.address)
      await expect(tx)
        .to.emit(requestKeyFacet, 'RequestKeyUpdated')
        .withArgs(previousKey, newKey, owner.address)

      expect(await ownershipFacet.owner()).to.equal(addr1.address)
      expect(await governanceLensFacet.returnRequestKey()).to.equal(newKey)
    })

    it('rejects a requestKey equal to the new owner', async function () {
      const { ownershipFacet, owner, addr1 } = await loadFixture(deployRequestKeyFixture)
      await expect(
        ownershipFacet.connect(owner)['transferOwnership(address,address)'](addr1.address, addr1.address)
      ).to.be.revertedWith('RequestKey: equals owner')
    })

    it('rejects a zero new owner', async function () {
      const { ownershipFacet, owner } = await loadFixture(deployRequestKeyFixture)
      await expect(
        ownershipFacet.connect(owner)['transferOwnership(address,address)'](ethers.ZeroAddress, freshKey())
      ).to.be.revertedWith('New owner cannot be zero address')
    })

    it('reverts for a non-owner caller', async function () {
      const { ownershipFacet, addr1, addr2 } = await loadFixture(deployRequestKeyFixture)
      await expect(
        ownershipFacet.connect(addr1)['transferOwnership(address,address)'](addr2.address, freshKey())
      ).to.be.revertedWith('LibDiamond: Must be contract owner')
    })
  })

  describe('Admin-election rotation', function () {
    // Mirrors the ratify pattern used in VoxGovernanceFacet.js: fund a voter above quorum, apply,
    // vote, advance past the deadline, then ratify.
    async function driveElection(fixture, { candidate, candidateKey, voter }) {
      const { governanceFacet, governanceLensFacet, tokenFacet, owner } = fixture

      const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()
      const totalSupply = await tokenFacet.totalSupply()
      const quorumAmount = (totalSupply * BigInt(currentQuotas.voxAdminChangeQuorum)) / 100n
      const votingAmount = quorumAmount + ethers.parseEther('1000')

      await tokenFacet.connect(owner).transfer(voter.address, votingAmount)
      await ethers.provider.send('hardhat_mine', ['0x3'])

      await governanceFacet.connect(candidate).applyAsNewAdmin('ipfs://candidate', candidateKey, {
        value: currentQuotas.adminApplicantFeeInPolWei
      })
      await governanceFacet.connect(voter).voteForNewAdmin(candidate.address)

      const [, , , , , , adminVoteDeadline] = await governanceLensFacet.returnGovernanceStorage()
      const currentBlock = await ethers.provider.getBlockNumber()
      await ethers.provider.send('hardhat_mine', ['0x' + (Number(adminVoteDeadline) - currentBlock + 1).toString(16)])
    }

    it('activates a non-incumbent winner’s supplied key on ratify', async function () {
      const fixture = await loadFixture(deployRequestKeyFixture)
      const { governanceFacet, governanceLensFacet, ownershipFacet, owner, addr1, addr2 } = fixture

      const candidateKey = freshKey()
      await driveElection(fixture, { candidate: addr1, candidateKey, voter: addr2 })

      await expect(governanceFacet.ratifyNewAdmin())
        .to.emit(ownershipFacet, 'OwnershipTransferred')
        .withArgs(owner.address, addr1.address)

      expect(await ownershipFacet.owner()).to.equal(addr1.address)
      expect(await governanceLensFacet.returnRequestKey()).to.equal(candidateKey)
    })

    it('rejects an application whose key equals the current live requestKey', async function () {
      // Uses addr2 as the applicant: the seeded requestKey is Hardhat account #1 (== addr1), so a
      // different applicant is needed for the `unchanged` check to fire before `equals owner`.
      const { governanceFacet, governanceLensFacet, addr2 } = await loadFixture(deployRequestKeyFixture)
      const current = await governanceLensFacet.returnRequestKey()
      const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()

      await expect(
        governanceFacet.connect(addr2).applyAsNewAdmin('ipfs://x', current, {
          value: currentQuotas.adminApplicantFeeInPolWei
        })
      ).to.be.revertedWith('RequestKey: unchanged')
    })

    it('rejects an application whose key equals the signing address', async function () {
      const { governanceFacet, governanceLensFacet, signingAddress, addr1 } = await loadFixture(deployRequestKeyFixture)
      const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()

      await expect(
        governanceFacet.connect(addr1).applyAsNewAdmin('ipfs://x', signingAddress, {
          value: currentQuotas.adminApplicantFeeInPolWei
        })
      ).to.be.revertedWith('RequestKey: equals signer')
    })

    it('rejects an application with a zero key', async function () {
      const { governanceFacet, governanceLensFacet, addr1 } = await loadFixture(deployRequestKeyFixture)
      const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()

      await expect(
        governanceFacet.connect(addr1).applyAsNewAdmin('ipfs://x', ethers.ZeroAddress, {
          value: currentQuotas.adminApplicantFeeInPolWei
        })
      ).to.be.revertedWith('RequestKey: zero')
    })

    it('keeps the current requestKey when the incumbent is re-elected', async function () {
      const fixture = await loadFixture(deployRequestKeyFixture)
      const { governanceFacet, governanceLensFacet, tokenFacet, ownershipFacet, owner, addr1 } = fixture

      const keyBefore = await governanceLensFacet.returnRequestKey()

      const [, , , currentQuotas] = await governanceLensFacet.returnGovernanceStorage()

      // A non-incumbent applies, which auto-adds the incumbent (owner) as candidate 0.
      await governanceFacet.connect(addr1).applyAsNewAdmin('ipfs://challenger', freshKey(), {
        value: currentQuotas.adminApplicantFeeInPolWei
      })

      // The owner holds the supply; vote it entirely for the incumbent so the incumbent wins.
      await ethers.provider.send('hardhat_mine', ['0x3'])
      await governanceFacet.connect(owner).voteForNewAdmin(owner.address)

      const [, , , , , , adminVoteDeadline] = await governanceLensFacet.returnGovernanceStorage()
      const currentBlock = await ethers.provider.getBlockNumber()
      await ethers.provider.send('hardhat_mine', ['0x' + (Number(adminVoteDeadline) - currentBlock + 1).toString(16)])

      await expect(governanceFacet.ratifyNewAdmin())
        .to.emit(ownershipFacet, 'OwnershipTransferred')
        .withArgs(owner.address, owner.address)

      // Incumbent retained ownership and the key was NOT rotated to address(0).
      expect(await ownershipFacet.owner()).to.equal(owner.address)
      expect(await governanceLensFacet.returnRequestKey()).to.equal(keyBefore)
    })
  })
})
