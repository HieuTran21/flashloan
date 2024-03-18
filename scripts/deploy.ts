import { ethers } from "hardhat";

async function main() {
  const addressProvider = process.env.ADDRESS_PROVIDER;
  const flashloan = await ethers.deployContract("Flashloan", [addressProvider]);

  await flashloan.waitForDeployment();
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
