const { ethers } = require("hardhat");
require("dotenv").config();

function requireEnv(name) {
  const value = process.env[name];

  if (!value || value.trim() === "") {
    throw new Error(`Missing environment variable: ${name}`);
  }

  return value.trim();
}

async function main() {
  const usdtAddress = requireEnv("USDT_ADDRESS");
  const gbcAddress = requireEnv("GBC_ADDRESS");

  const [deployer] = await ethers.getSigners();

  const ownerAddress =
    process.env.OWNER_ADDRESS && process.env.OWNER_ADDRESS.trim() !== ""
      ? process.env.OWNER_ADDRESS.trim()
      : deployer.address;

  console.log("Deploying StakeMint...");
  console.log("Deployer:", deployer.address);
  console.log("Initial owner:", ownerAddress);
  console.log("USDT:", usdtAddress);
  console.log("GBC:", gbcAddress);

  const StakeMint = await ethers.getContractFactory("StakeMint");

  const stakeMint = await StakeMint.deploy(
    usdtAddress,
    gbcAddress,
    ownerAddress
  );

  await stakeMint.waitForDeployment();

  const stakeMintAddress = await stakeMint.getAddress();

  console.log("");
  console.log("StakeMint deployed:", stakeMintAddress);

  const stakeUnit = await stakeMint.STAKE_UNIT();
  const updateInterval = await stakeMint.UPDATE_INTERVAL();
  const timeInterval = await stakeMint.TIMEINTERVAL();

  console.log("STAKE_UNIT:", stakeUnit.toString());
  console.log("UPDATE_INTERVAL:", updateInterval.toString());
  console.log("TIMEINTERVAL:", timeInterval.toString());

  console.log("");
  console.log("Constructor args for verification:");
  console.log(
    JSON.stringify(
      [usdtAddress, gbcAddress, ownerAddress],
      null,
      2
    )
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});