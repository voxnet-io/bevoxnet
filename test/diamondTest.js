/* global describe it before ethers */

const {
  getSelectors,
  FacetCutAction,
  removeSelectors,
  findAddressPositionInFacets
} = require('../scripts/libraries/diamond.js')

const { deployDiamond } = require('../scripts/deploy.js')

const { assert, expect } = require('chai')

describe('DiamondTest', async function () {
  let diamondAddress
  let diamondCutFacet
  let diamondLoupeFacet
  let ownershipFacet
  let tx
  let receipt
  let result
  const addresses = []

  before(async function () {
    diamondAddress = await deployDiamond()
    diamondCutFacet = await ethers.getContractAt('DiamondCutFacet', diamondAddress)
    diamondLoupeFacet = await ethers.getContractAt('DiamondLoupeFacet', diamondAddress)
    ownershipFacet = await ethers.getContractAt('OwnershipFacet', diamondAddress)
  })

  // 10 facets (added TokenLensFacet)
  it('should have ten facets -- call to facetAddresses function', async () => {
    for (const address of await diamondLoupeFacet.facetAddresses()) {
      addresses.push(address)
    }

    console.log('Deployed facets:', addresses.length)
    console.log('Facet addresses:', addresses)
    assert.equal(addresses.length, 10) // DiamondCut, DiamondLoupe, Ownership, Token, Governance, Vox, ChapterLens, VoxAssistant, GovernanceLens, TokenLens
  })

  it('facets should have the right function selectors -- call to facetFunctionSelectors function', async () => {
    let selectors = getSelectors(diamondCutFacet)
    result = await diamondLoupeFacet.facetFunctionSelectors(addresses[0])
    assert.sameMembers(Array.from(result), selectors)
    
    selectors = getSelectors(diamondLoupeFacet)
    result = await diamondLoupeFacet.facetFunctionSelectors(addresses[1])
    assert.sameMembers(Array.from(result), selectors)
    
    selectors = getSelectors(ownershipFacet)
    result = await diamondLoupeFacet.facetFunctionSelectors(addresses[2])
    assert.sameMembers(Array.from(result), selectors)
  })

  it('selectors should be associated to facets correctly -- multiple calls to facetAddress function', async () => {
    assert.equal(
      addresses[0],
      await diamondLoupeFacet.facetAddress('0x1f931c1c')
    )
    assert.equal(
      addresses[1],
      await diamondLoupeFacet.facetAddress('0xcdffacc6')
    )
    assert.equal(
      addresses[1],
      await diamondLoupeFacet.facetAddress('0x01ffc9a7')
    )
    assert.equal(
      addresses[2],
      await diamondLoupeFacet.facetAddress('0xf2fde38b')
    )
  })

  it('should add test1 functions', async () => {
    const Test1Facet = await ethers.getContractFactory('Test1Facet')
    const test1Facet = await Test1Facet.deploy()
    await test1Facet.waitForDeployment()
    const test1Address = await test1Facet.getAddress()
    addresses.push(test1Address)
    
    const selectors = getSelectors(test1Facet).remove(['supportsInterface(bytes4)'])
    
    tx = await diamondCutFacet.diamondCut(
      [{
        facetAddress: test1Address,
        action: FacetCutAction.Add,
        functionSelectors: selectors
      }],
      ethers.ZeroAddress, '0x', { gasLimit: 800000 })
    receipt = await tx.wait()
    if (!receipt.status) {
      throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    result = await diamondLoupeFacet.facetFunctionSelectors(test1Address)
    assert.sameMembers(Array.from(result), selectors)
  })

  it('should test function call', async () => {
    const test1Facet = await ethers.getContractAt('Test1Facet', diamondAddress)
    await test1Facet.test1Func10()
  })

  // Test1Facet is at index 10 now
  it('should replace supportsInterface function', async () => {
    const test1Address = addresses[10] // Test1Facet is at index 10 now
    const test1Facet = await ethers.getContractAt('Test1Facet', test1Address)
    const selectors = getSelectors(test1Facet).get(['supportsInterface(bytes4)'])
    
    tx = await diamondCutFacet.diamondCut(
      [{
        facetAddress: test1Address,
        action: FacetCutAction.Replace,
        functionSelectors: selectors
      }],
      ethers.ZeroAddress, '0x', { gasLimit: 800000 })
    receipt = await tx.wait()
    if (!receipt.status) {
      throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    
    // Get fresh selectors from the deployed instance
    const test1FacetAfter = await ethers.getContractAt('Test1Facet', test1Address)
    result = await diamondLoupeFacet.facetFunctionSelectors(test1Address)
    assert.sameMembers(Array.from(result), getSelectors(test1FacetAfter))
  })

  it('should add test2 functions', async () => {
    const Test2Facet = await ethers.getContractFactory('Test2Facet')
    const test2Facet = await Test2Facet.deploy()
    await test2Facet.waitForDeployment()
    const test2Address = await test2Facet.getAddress()
    addresses.push(test2Address)
    
    const selectors = getSelectors(test2Facet)
    tx = await diamondCutFacet.diamondCut(
      [{
        facetAddress: test2Address,
        action: FacetCutAction.Add,
        functionSelectors: selectors
      }],
      ethers.ZeroAddress, '0x', { gasLimit: 800000 })
    receipt = await tx.wait()
    if (!receipt.status) {
      throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    result = await diamondLoupeFacet.facetFunctionSelectors(test2Address)
    assert.sameMembers(Array.from(result), selectors)
  })

  // Test2Facet is at index 11
  it('should remove some test2 functions', async () => {
    const test2Address = addresses[11] // Test2Facet is at index 11
    const test2Facet = await ethers.getContractAt('Test2Facet', test2Address)
    const functionsToKeep = ['test2Func1()', 'test2Func5()', 'test2Func6()', 'test2Func19()', 'test2Func20()']
    
    const selectors = getSelectors(test2Facet)
    const selectorsToRemove = selectors.remove(functionsToKeep)
    
    tx = await diamondCutFacet.diamondCut(
      [{
        facetAddress: ethers.ZeroAddress,
        action: FacetCutAction.Remove,
        functionSelectors: selectorsToRemove
      }],
      ethers.ZeroAddress, '0x', { gasLimit: 800000 })
    receipt = await tx.wait()
    if (!receipt.status) {
      throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    result = await diamondLoupeFacet.facetFunctionSelectors(test2Address)
    assert.sameMembers(Array.from(result), selectors.get(functionsToKeep))
  })

  // Test1Facet at index 10
  it('should remove some test1 functions', async () => {
    const test1Address = addresses[10] // Test1Facet is at index 10
    const test1Facet = await ethers.getContractAt('Test1Facet', test1Address)
    const functionsToKeep = ['test1Func2()', 'test1Func11()', 'test1Func12()']
    
    const selectors = getSelectors(test1Facet)
    const selectorsToRemove = selectors.remove(functionsToKeep)
    
    tx = await diamondCutFacet.diamondCut(
      [{
        facetAddress: ethers.ZeroAddress,
        action: FacetCutAction.Remove,
        functionSelectors: selectorsToRemove
      }],
      ethers.ZeroAddress, '0x', { gasLimit: 800000 })
    receipt = await tx.wait()
    if (!receipt.status) {
      throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    result = await diamondLoupeFacet.facetFunctionSelectors(test1Address)
    assert.sameMembers(Array.from(result), selectors.get(functionsToKeep))
  })

  it('reverts when a cut removes a protected selector (diamondCut / loupe)', async () => {
    // The classic "strip down to diamondCut + facets()" now hits the protected-selector guard,
    // because it would remove the loupe selectors.
    let selectors = []
    const facets = await diamondLoupeFacet.facets()
    for (let i = 0; i < facets.length; i++) {
      selectors.push(...facets[i].functionSelectors)
    }
    selectors = removeSelectors(selectors, ['facets()', 'diamondCut(tuple(address,uint8,bytes4[])[],address,bytes)'])

    await expect(
      diamondCutFacet.diamondCut(
        [{ facetAddress: ethers.ZeroAddress, action: FacetCutAction.Remove, functionSelectors: selectors }],
        ethers.ZeroAddress, '0x', { gasLimit: 8000000 })
    ).to.be.revertedWith('LibDiamond: Cannot remove protected selector')

    // Each protected loupe selector reverts individually: facetAddresses, facetAddress.
    for (const protectedSel of ['0x52ef6b2c', '0xcdffacc6']) {
      await expect(
        diamondCutFacet.diamondCut(
          [{ facetAddress: ethers.ZeroAddress, action: FacetCutAction.Remove, functionSelectors: [protectedSel] }],
          ethers.ZeroAddress, '0x')
      ).to.be.revertedWith('LibDiamond: Cannot remove protected selector')
    }
  })

  it('allows removing and re-adding a non-protected function', async () => {
    const ownershipSel = getSelectors(ownershipFacet).get(['isOwner()'])
    const ownAddr = addresses[2] // OwnershipFacet

    // Remove a non-protected selector — allowed.
    await (await diamondCutFacet.diamondCut(
      [{ facetAddress: ethers.ZeroAddress, action: FacetCutAction.Remove, functionSelectors: ownershipSel }],
      ethers.ZeroAddress, '0x')).wait()
    assert.equal(await diamondLoupeFacet.facetAddress(ownershipSel[0]), ethers.ZeroAddress)

    // Re-add it.
    await (await diamondCutFacet.diamondCut(
      [{ facetAddress: ownAddr, action: FacetCutAction.Add, functionSelectors: ownershipSel }],
      ethers.ZeroAddress, '0x')).wait()
    assert.equal(await diamondLoupeFacet.facetAddress(ownershipSel[0]), ownAddr)
  })
})
