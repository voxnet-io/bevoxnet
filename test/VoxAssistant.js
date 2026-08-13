// Vox VoxAssistant role tests
// Covers:
//   - Invitation lifecycle (invite / accept / decline / revoke)
//   - Role removal (owner-removed / self-resign)
//   - Delegated powers (ban/unban users at platform level)
//   - Auto-cleanup on platform ban (active assistant + pending invite)
//   - View functions
//   - Negative: VoxAssistant cannot exercise VOX-only powers
//
// Run with: npx hardhat test test/VoxVoxAssistant.js

const { expect } = require('chai')
const { ethers } = require('hardhat')
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers')

const { deployDiamond } = require('../scripts/deploy.js')

describe('VoxAssistant Role', function () {
  async function deployFixture() {
    const [owner, voxa1, voxa2, candidate, user, outsider] = await ethers.getSigners()

    const diamondAddress = await deployDiamond()
    const governanceFacet = await ethers.getContractAt('VoxGovernanceFacet', diamondAddress)
    const voxAssistantFacet = await ethers.getContractAt('VoxAssistantFacet', diamondAddress)
    const voxFacet = await ethers.getContractAt('VoxFacet', diamondAddress)
    const ownershipFacet = await ethers.getContractAt('OwnershipFacet', diamondAddress)

    return {
      diamondAddress,
      governanceFacet,
      voxAssistantFacet,
      voxFacet,
      ownershipFacet,
      owner,
      voxa1,
      voxa2,
      candidate,
      user,
      outsider,
    }
  }

  // ==========================================================================
  // INVITATION LIFECYCLE
  // ==========================================================================
  describe('Invitation lifecycle', function () {
    it('owner invites a candidate; pending state is set', async function () {
      const { governanceFacet, voxAssistantFacet, owner, candidate } = await loadFixture(deployFixture)

      await expect(voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address))
        .to.emit(voxAssistantFacet, 'VoxAssistantInvited')

      expect(await voxAssistantFacet.isVoxAssistantAddress(candidate.address)).to.be.false

      const pending = await voxAssistantFacet.getPendingVoxAssistantInvitations()
      expect(pending).to.include(candidate.address)

      const [hasInvite, sentAt] = await voxAssistantFacet.getVoxAssistantInvitationDetails(candidate.address)
      expect(hasInvite).to.be.true
      expect(sentAt).to.be.gt(0)
    })

    it('rejects inviting the zero address', async function () {
      const { governanceFacet, voxAssistantFacet, owner } = await loadFixture(deployFixture)
      await expect(
        voxAssistantFacet.connect(owner).inviteVoxAssistant(ethers.ZeroAddress)
      ).to.be.revertedWith('Z')
    })

    it('rejects self-invite by the owner', async function () {
      const { governanceFacet, voxAssistantFacet, owner } = await loadFixture(deployFixture)
      await expect(
        voxAssistantFacet.connect(owner).inviteVoxAssistant(owner.address)
      ).to.be.revertedWith('SELF')
    })

    it('rejects inviting an address already invited', async function () {
      const { governanceFacet, voxAssistantFacet, owner, candidate } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)
      await expect(
        voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)
      ).to.be.revertedWith('INV')
    })

    it('rejects inviting an already-active assistant', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1 } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa1.address)
      await voxAssistantFacet.connect(voxa1).acceptVoxAssistantInvitation()
      await expect(
        voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa1.address)
      ).to.be.revertedWith('VOXA')
    })

    it('rejects inviting a platform-banned user', async function () {
      const { governanceFacet, voxAssistantFacet, owner, candidate } = await loadFixture(deployFixture)
      await governanceFacet.connect(owner).banUserFromPlatform(candidate.address)
      await expect(
        voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)
      ).to.be.revertedWith('BAN')
    })

    it('rejects non-owner inviters', async function () {
      const { governanceFacet, voxAssistantFacet, outsider, candidate } = await loadFixture(deployFixture)
      await expect(
        voxAssistantFacet.connect(outsider).inviteVoxAssistant(candidate.address)
      ).to.be.revertedWith('LibDiamond: Must be contract owner')
    })

    it('candidate accepts; becomes active and invite is cleared', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1 } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa1.address)

      await expect(voxAssistantFacet.connect(voxa1).acceptVoxAssistantInvitation())
        .to.emit(voxAssistantFacet, 'VoxAssistantInvitationAccepted')

      expect(await voxAssistantFacet.isVoxAssistantAddress(voxa1.address)).to.be.true
      expect(await voxAssistantFacet.getVoxAssistantCount()).to.equal(1)

      const [hasInvite] = await voxAssistantFacet.getVoxAssistantInvitationDetails(voxa1.address)
      expect(hasInvite).to.be.false

      const pending = await voxAssistantFacet.getPendingVoxAssistantInvitations()
      expect(pending).to.not.include(voxa1.address)
    })

    it('rejects accept without a pending invitation', async function () {
      const { governanceFacet, voxAssistantFacet, outsider } = await loadFixture(deployFixture)
      await expect(
        voxAssistantFacet.connect(outsider).acceptVoxAssistantInvitation()
      ).to.be.revertedWith('INV')
    })

    it('rejects accept if candidate was platform-banned after invite', async function () {
      const { governanceFacet, voxAssistantFacet, owner, candidate } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)
      // banUserFromPlatform auto-revokes the invite (tested separately), so to
      // reach the BAN guard in acceptVoxAssistantInvitation the invite must still
      // be live. We therefore craft the scenario by first banning *directly*
      // against a candidate who was invited before the ban could clean it up:
      // cheat by re-inviting after the ban is lifted is not representative.
      // Instead verify the auto-clean path here — the invite must be gone.
      await governanceFacet.connect(owner).banUserFromPlatform(candidate.address)
      await expect(
        voxAssistantFacet.connect(candidate).acceptVoxAssistantInvitation()
      ).to.be.revertedWith('INV')
    })

    it('candidate declines; invite is cleared, no active role', async function () {
      const { governanceFacet, voxAssistantFacet, owner, candidate } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)

      await expect(voxAssistantFacet.connect(candidate).declineVoxAssistantInvitation())
        .to.emit(voxAssistantFacet, 'VoxAssistantInvitationDeclined')

      expect(await voxAssistantFacet.isVoxAssistantAddress(candidate.address)).to.be.false
      const [hasInvite] = await voxAssistantFacet.getVoxAssistantInvitationDetails(candidate.address)
      expect(hasInvite).to.be.false
    })

    it('rejects decline without a pending invitation', async function () {
      const { governanceFacet, voxAssistantFacet, outsider } = await loadFixture(deployFixture)
      await expect(
        voxAssistantFacet.connect(outsider).declineVoxAssistantInvitation()
      ).to.be.revertedWith('INV')
    })

    it('owner revokes a pending invitation', async function () {
      const { governanceFacet, voxAssistantFacet, owner, candidate } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)

      await expect(voxAssistantFacet.connect(owner).revokeVoxAssistantInvitation(candidate.address))
        .to.emit(governanceFacet, 'VoxAssistantInvitationRevoked')

      const [hasInvite] = await voxAssistantFacet.getVoxAssistantInvitationDetails(candidate.address)
      expect(hasInvite).to.be.false
    })

    it('rejects revoke when no invitation is pending', async function () {
      const { governanceFacet, voxAssistantFacet, owner, candidate } = await loadFixture(deployFixture)
      await expect(
        voxAssistantFacet.connect(owner).revokeVoxAssistantInvitation(candidate.address)
      ).to.be.revertedWith('INV')
    })

    it('rejects non-owner revoke', async function () {
      const { governanceFacet, voxAssistantFacet, owner, candidate, outsider } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)
      await expect(
        voxAssistantFacet.connect(outsider).revokeVoxAssistantInvitation(candidate.address)
      ).to.be.revertedWith('LibDiamond: Must be contract owner')
    })
  })

  // ==========================================================================
  // ROLE REMOVAL
  // ==========================================================================
  describe('Role removal', function () {
    it('owner removes an active assistant', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1 } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa1.address)
      await voxAssistantFacet.connect(voxa1).acceptVoxAssistantInvitation()

      await expect(voxAssistantFacet.connect(owner).removeVoxAssistant(voxa1.address))
        .to.emit(governanceFacet, 'VoxAssistantRemoved')

      expect(await voxAssistantFacet.isVoxAssistantAddress(voxa1.address)).to.be.false
      expect(await voxAssistantFacet.getVoxAssistantCount()).to.equal(0)
    })

    it('rejects removing a non-assistant', async function () {
      const { governanceFacet, voxAssistantFacet, owner, outsider } = await loadFixture(deployFixture)
      await expect(
        voxAssistantFacet.connect(owner).removeVoxAssistant(outsider.address)
      ).to.be.revertedWith('VOXA')
    })

    it('rejects non-owner removal', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1, outsider } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa1.address)
      await voxAssistantFacet.connect(voxa1).acceptVoxAssistantInvitation()
      await expect(
        voxAssistantFacet.connect(outsider).removeVoxAssistant(voxa1.address)
      ).to.be.revertedWith('LibDiamond: Must be contract owner')
    })

    it('assistant resigns', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1 } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa1.address)
      await voxAssistantFacet.connect(voxa1).acceptVoxAssistantInvitation()

      await expect(voxAssistantFacet.connect(voxa1).resignAsVoxAssistant())
        .to.emit(voxAssistantFacet, 'VoxAssistantResigned')

      expect(await voxAssistantFacet.isVoxAssistantAddress(voxa1.address)).to.be.false
    })

    it('rejects resign from non-assistant', async function () {
      const { governanceFacet, voxAssistantFacet, outsider } = await loadFixture(deployFixture)
      await expect(
        voxAssistantFacet.connect(outsider).resignAsVoxAssistant()
      ).to.be.revertedWith('VOXA')
    })

    it('swap-and-pop keeps array consistent across removals', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1, voxa2, candidate } = await loadFixture(deployFixture)

      for (const s of [voxa1, voxa2, candidate]) {
        await voxAssistantFacet.connect(owner).inviteVoxAssistant(s.address)
        await voxAssistantFacet.connect(s).acceptVoxAssistantInvitation()
      }
      expect(await voxAssistantFacet.getVoxAssistantCount()).to.equal(3)

      // Remove the middle one
      await voxAssistantFacet.connect(owner).removeVoxAssistant(voxa2.address)
      expect(await voxAssistantFacet.getVoxAssistantCount()).to.equal(2)

      const list = await voxAssistantFacet.getVoxAssistants()
      expect(list).to.include(voxa1.address)
      expect(list).to.include(candidate.address)
      expect(list).to.not.include(voxa2.address)
    })
  })

  // ==========================================================================
  // DELEGATED POWERS
  // ==========================================================================
  describe('Delegated powers', function () {
    async function activeAssistantFixture() {
      const base = await deployFixture()
      await base.voxAssistantFacet.connect(base.owner).inviteVoxAssistant(base.voxa1.address)
      await base.voxAssistantFacet.connect(base.voxa1).acceptVoxAssistantInvitation()
      return base
    }

    it('VoxAssistant can banUserFromPlatform', async function () {
      const { governanceFacet, voxAssistantFacet, voxFacet, voxa1, user } = await loadFixture(activeAssistantFixture)

      await expect(governanceFacet.connect(voxa1).banUserFromPlatform(user.address))
        .to.emit(governanceFacet, 'UserBanned')

      expect(await voxFacet.isUserBannedFromPlatform(user.address)).to.be.true
    })

    it('VoxAssistant can unbanUserFromPlatform', async function () {
      const { governanceFacet, voxAssistantFacet, voxFacet, owner, voxa1, user } = await loadFixture(activeAssistantFixture)

      await governanceFacet.connect(owner).banUserFromPlatform(user.address)
      expect(await voxFacet.isUserBannedFromPlatform(user.address)).to.be.true

      await expect(governanceFacet.connect(voxa1).unbanUserFromPlatform(user.address))
        .to.emit(governanceFacet, 'UserUnbanned')

      expect(await voxFacet.isUserBannedFromPlatform(user.address)).to.be.false
    })

    it('non-owner non-assistant still rejected with VOXA', async function () {
      const { governanceFacet, voxAssistantFacet, outsider, user } = await loadFixture(activeAssistantFixture)
      await expect(
        governanceFacet.connect(outsider).banUserFromPlatform(user.address)
      ).to.be.revertedWith('VOXA')
    })

    it('former assistant loses delegated power after removal', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1, user } = await loadFixture(activeAssistantFixture)
      await voxAssistantFacet.connect(owner).removeVoxAssistant(voxa1.address)
      await expect(
        governanceFacet.connect(voxa1).banUserFromPlatform(user.address)
      ).to.be.revertedWith('VOXA')
    })

    it('VoxAssistant cannot call VOX-only functions (transferOwnership)', async function () {
      const { ownershipFacet, voxa1, outsider } = await loadFixture(activeAssistantFixture)
      await expect(
        ownershipFacet.connect(voxa1).transferOwnership(outsider.address)
      ).to.be.revertedWith('LibDiamond: Must be contract owner')
    })
  })

  // ==========================================================================
  // AUTO-CLEANUP ON PLATFORM BAN
  // ==========================================================================
  describe('Auto-cleanup on platform ban', function () {
    it('banning an active assistant auto-removes the role', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1 } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa1.address)
      await voxAssistantFacet.connect(voxa1).acceptVoxAssistantInvitation()
      expect(await voxAssistantFacet.isVoxAssistantAddress(voxa1.address)).to.be.true

      await expect(governanceFacet.connect(owner).banUserFromPlatform(voxa1.address))
        .to.emit(governanceFacet, 'VoxAssistantRemoved')
        .and.to.emit(governanceFacet, 'UserBanned')

      expect(await voxAssistantFacet.isVoxAssistantAddress(voxa1.address)).to.be.false
      expect(await voxAssistantFacet.getVoxAssistantCount()).to.equal(0)
    })

    it('banning an invited candidate auto-revokes the invitation', async function () {
      const { governanceFacet, voxAssistantFacet, owner, candidate } = await loadFixture(deployFixture)
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)

      const [hadInviteBefore] = await voxAssistantFacet.getVoxAssistantInvitationDetails(candidate.address)
      expect(hadInviteBefore).to.be.true

      await expect(governanceFacet.connect(owner).banUserFromPlatform(candidate.address))
        .to.emit(governanceFacet, 'VoxAssistantInvitationRevoked')
        .and.to.emit(governanceFacet, 'UserBanned')

      const [hasInviteAfter] = await voxAssistantFacet.getVoxAssistantInvitationDetails(candidate.address)
      expect(hasInviteAfter).to.be.false

      const pending = await voxAssistantFacet.getPendingVoxAssistantInvitations()
      expect(pending).to.not.include(candidate.address)
    })

    it('unbanning does not restore the role or the invitation', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1, candidate } = await loadFixture(deployFixture)

      // Active assistant
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa1.address)
      await voxAssistantFacet.connect(voxa1).acceptVoxAssistantInvitation()
      await governanceFacet.connect(owner).banUserFromPlatform(voxa1.address)
      await governanceFacet.connect(owner).unbanUserFromPlatform(voxa1.address)
      expect(await voxAssistantFacet.isVoxAssistantAddress(voxa1.address)).to.be.false

      // Invited candidate
      await voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)
      await governanceFacet.connect(owner).banUserFromPlatform(candidate.address)
      await governanceFacet.connect(owner).unbanUserFromPlatform(candidate.address)
      const [hasInvite] = await voxAssistantFacet.getVoxAssistantInvitationDetails(candidate.address)
      expect(hasInvite).to.be.false
    })
  })

  // ==========================================================================
  // VIEW FUNCTIONS
  // ==========================================================================
  describe('View functions', function () {
    it('empty state', async function () {
      const { governanceFacet, voxAssistantFacet } = await loadFixture(deployFixture)
      expect(await voxAssistantFacet.getVoxAssistantCount()).to.equal(0)
      expect((await voxAssistantFacet.getVoxAssistants()).length).to.equal(0)
      expect((await voxAssistantFacet.getPendingVoxAssistantInvitations()).length).to.equal(0)
    })

    it('enumerates active assistants and pending invites separately', async function () {
      const { governanceFacet, voxAssistantFacet, owner, voxa1, voxa2, candidate } = await loadFixture(deployFixture)

      await voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa1.address)
      await voxAssistantFacet.connect(voxa1).acceptVoxAssistantInvitation()

      await voxAssistantFacet.connect(owner).inviteVoxAssistant(voxa2.address)
      await voxAssistantFacet.connect(voxa2).acceptVoxAssistantInvitation()

      await voxAssistantFacet.connect(owner).inviteVoxAssistant(candidate.address)

      const active = await voxAssistantFacet.getVoxAssistants()
      expect(active).to.have.length(2)
      expect(active).to.include(voxa1.address)
      expect(active).to.include(voxa2.address)

      const pending = await voxAssistantFacet.getPendingVoxAssistantInvitations()
      expect(pending).to.have.length(1)
      expect(pending[0]).to.equal(candidate.address)
    })
  })
})
