const { ethers } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying with account:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Account balance:", ethers.formatEther(balance), "ETH");

    // Configuration
    const TOKEN_NAME = "EmissionToken";
    const TOKEN_SYMBOL = "EMT";
    const MAX_SUPPLY = ethers.parseEther("1000000");         // 1M tokens
    const EMISSION_RATE = ethers.parseEther("0.01");          // 0.01 per block per whole token

    console.log("\nDeploying EmissionToken...");
    console.log("  Name:", TOKEN_NAME);
    console.log("  Symbol:", TOKEN_SYMBOL);
    console.log("  Max Supply:", ethers.formatEther(MAX_SUPPLY));
    console.log("  Emission Rate:", ethers.formatEther(EMISSION_RATE), "per block per token");

    const EmissionToken = await ethers.getContractFactory("EmissionToken");
    const token = await EmissionToken.deploy(
        TOKEN_NAME,
        TOKEN_SYMBOL,
        MAX_SUPPLY,
        EMISSION_RATE
    );

    await token.waitForDeployment();
    const address = await token.getAddress();

    console.log("\nEmissionToken deployed to:", address);
    console.log("\nVerify with:");
    console.log(`  npx hardhat verify --network arbitrumOne ${address} "${TOKEN_NAME}" "${TOKEN_SYMBOL}" "${MAX_SUPPLY}" "${EMISSION_RATE}"`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
