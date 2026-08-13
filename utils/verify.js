const { run } = require("hardhat");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Etherscan often lags chain state on mainnet, so the first verify attempt right
// after deployment can fail with a transient "not yet indexed / no bytecode" error.
// Retry those before giving up; non-transient failures return without blocking the deploy.
const verify = async (contractAddress, args, retries = 5, delayMs = 15000) => {
  for (let attempt = 1; attempt <= retries; attempt++) {
    console.log(`Verifying ${contractAddress} (attempt ${attempt}/${retries})...`);
    try {
      await run("verify:verify", {
        address: contractAddress,
        constructorArguments: args,
      });
      console.log("Verified:", contractAddress);
      return;
    } catch (e) {
      const msg = (e.message || "").toLowerCase();
      if (msg.includes("already verified")) {
        console.log("Already verified:", contractAddress);
        return;
      }
      const transient =
        msg.includes("does not have bytecode") ||
        msg.includes("has not been indexed") ||
        msg.includes("unable to locate contractcode") ||
        msg.includes("not yet indexed") ||
        msg.includes("timeout") ||
        msg.includes("rate limit");
      if (transient && attempt < retries) {
        console.log(`Transient verify error, retrying in ${delayMs / 1000}s: ${e.message}`);
        await sleep(delayMs);
        continue;
      }
      console.log(`Verification failed for ${contractAddress}: ${e.message}`);
      return;
    }
  }
};

module.exports = { verify };
