/* global ethers */

const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 }

// Helper function to remove specific selectors
function remove (functionNames) {
  const iface = this.contract.interface
  const selectors = this.filter((v) => {
    for (const functionName of functionNames) {
      try {
        if (v === iface.getFunction(functionName).selector) {
          return false
        }
      } catch (e) {
        // Function not found, continue
      }
    }
    return true
  })
  selectors.contract = this.contract
  selectors.remove = remove
  selectors.get = get
  return selectors
}

// Helper function to get specific selectors
function get (functionNames) {
  const iface = this.contract.interface
  const selectors = this.filter((v) => {
    for (const functionName of functionNames) {
      try {
        if (v === iface.getFunction(functionName).selector) {
          return true
        }
      } catch (e) {
        // Function not found, continue
      }
    }
    return false
  })
  selectors.contract = this.contract
  selectors.remove = remove
  selectors.get = get
  return selectors
}

// get function selectors from ABI
function getSelectors (contract) {
  if (!contract || !contract.interface) {
    throw new Error('getSelectors: invalid contract or interface');
  }

  const iface = contract.interface;
  const selectors = [];

  // ✅ FIXED: Use forEachFunction for ethers v6
  if (typeof iface.forEachFunction === 'function') {
    iface.forEachFunction((fn) => {
      if (fn.name !== 'init') { // Exclude init function
        selectors.push(fn.selector);
      }
    });
  } else {
    throw new Error('getSelectors: unsupported interface version');
  }

  // ✅ Attach helper methods and contract reference
  selectors.contract = contract
  selectors.remove = remove
  selectors.get = get

  return selectors;
}

// get function selector from function signature
function getSelector (func) {
  const abiInterface = new ethers.Interface([func])
  return abiInterface.getFunction(func).selector
}

// remove selectors using an array of signatures
function removeSelectors (selectors, signatures) {
  const iface = new ethers.Interface(signatures.map(v => 'function ' + v))
  const removeSelectors = signatures.map(v => iface.getFunction(v).selector)
  selectors = selectors.filter(v => !removeSelectors.includes(v))
  return selectors
}

// find a particular address position in the return value of diamondLoupeFacet.facets()
function findAddressPositionInFacets (facetAddress, facets) {
  for (let i = 0; i < facets.length; i++) {
    if (facets[i].facetAddress === facetAddress || facets[i][0] === facetAddress) {
      return i
    }
  }
  return -1
}

exports.getSelectors = getSelectors
exports.getSelector = getSelector
exports.FacetCutAction = FacetCutAction
exports.remove = remove
exports.get = get
exports.removeSelectors = removeSelectors
exports.findAddressPositionInFacets = findAddressPositionInFacets
