/* global describe it before ethers */

const {
  getSelectors,
  FacetCutAction,
  removeSelectors,
  findAddressPositionInFacets
} = require('../scripts/libraries/diamond.js')

const { deployDiamond } = require('../scripts/deploy.js')

const { assert } = require('chai')

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
    
    // ✅ FIXED: Get fresh selectors from the deployed instance
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

  it('remove all functions and facets except \'diamondCut\' and \'facets\'', async () => {
    let selectors = []
    let facets = await diamondLoupeFacet.facets()
    for (let i = 0; i < facets.length; i++) {
      selectors.push(...facets[i].functionSelectors)
    }
    selectors = removeSelectors(selectors, ['facets()', 'diamondCut(tuple(address,uint8,bytes4[])[],address,bytes)'])
    
    tx = await diamondCutFacet.diamondCut(
      [{
        facetAddress: ethers.ZeroAddress,
        action: FacetCutAction.Remove,
        functionSelectors: selectors
      }],
      ethers.ZeroAddress, '0x', { gasLimit: 8000000 })
    receipt = await tx.wait()
    if (!receipt.status) {
      throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    facets = await diamondLoupeFacet.facets()
    assert.equal(facets.length, 2)
    assert.equal(facets[0][0], addresses[0])
    assert.sameMembers(Array.from(facets[0][1]), ['0x1f931c1c'])
    assert.equal(facets[1][0], addresses[1])
    assert.sameMembers(Array.from(facets[1][1]), ['0x7a0ed627'])
  })

  // ✅ FIXED: Expect 5 total facets (not 6)
  it('add most functions and facets', async () => {
    const diamondLoupeFacetSelectors = getSelectors(diamondLoupeFacet).remove(['supportsInterface(bytes4)', 'facets()'])
    
    const test1Address = addresses[10]
    const test2Address = addresses[11]
    const test1Facet = await ethers.getContractAt('Test1Facet', test1Address)
    const test2Facet = await ethers.getContractAt('Test2Facet', test2Address)
    
    const cut = [
      {
        facetAddress: addresses[1],
        action: FacetCutAction.Add,
        functionSelectors: diamondLoupeFacetSelectors
      },
      {
        facetAddress: addresses[2],
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(ownershipFacet)
      },
      {
        facetAddress: test1Address,
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(test1Facet)
      },
      {
        facetAddress: test2Address,
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(test2Facet)
      }
    ]
    
    tx = await diamondCutFacet.diamondCut(cut, ethers.ZeroAddress, '0x', { gasLimit: 8000000 })
    receipt = await tx.wait()
    if (!receipt.status) {
      throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    
    const facets = await diamondLoupeFacet.facets()
    const facetAddresses = await diamondLoupeFacet.facetAddresses()
    
    // ✅ FIXED: Expect 5 facets total
    // After removal: 2 facets remain (DiamondCut at addresses[0], DiamondLoupe at addresses[1] with only 'facets()')
    // After re-adding: 
    //   - DiamondLoupe (addresses[1]) gets more functions added (still same facet)
    //   - Ownership (addresses[2]) is added as NEW facet
    //   - Test1 (addresses[6]) is added as NEW facet  
    //   - Test2 (addresses[7]) is added as NEW facet
    // Total: 2 + 3 new = 5 facets
    assert.equal(facetAddresses.length, 5)
    assert.equal(facets.length, 5)
    
    assert.sameMembers(
      Array.from(facets[findAddressPositionInFacets(addresses[0], facets)][1]),
      getSelectors(diamondCutFacet)
    )
    
    // DiamondLoupe now has both the original 'facets()' and the newly added selectors
    const expectedLoupeSelectors = diamondLoupeFacetSelectors.concat(['0x7a0ed627'])
    assert.sameMembers(
      Array.from(facets[findAddressPositionInFacets(addresses[1], facets)][1]),
      expectedLoupeSelectors
    )
    
    assert.sameMembers(
      Array.from(facets[findAddressPositionInFacets(addresses[2], facets)][1]),
      getSelectors(ownershipFacet)
    )
    assert.sameMembers(
      Array.from(facets[findAddressPositionInFacets(test1Address, facets)][1]),
      getSelectors(test1Facet)
    )
    assert.sameMembers(
      Array.from(facets[findAddressPositionInFacets(test2Address, facets)][1]),
      getSelectors(test2Facet)
    )
  })
})
