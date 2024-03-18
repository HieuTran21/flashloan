import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-foundry";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-contract-sizer";
import "hardhat-gas-reporter";
import dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";

dotenv.config();

const privateKey = process.env.PRIVATE_KEY as any;
const infuraKey = process.env.INFURA_KEY as any;
const ethereumApiKey = process.env.ETHEREUM_API_KEY as any;

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      gas: 12000000,
      blockGasLimit: 0x1fffffffffffff,
      allowUnlimitedContractSize: true,
      forking: {
        url: `https://sepolia.infura.io/v3/${infuraKey}`,
      },
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${infuraKey}`,
      accounts: [privateKey],
    },
    ethereum: {
      chainId: 1,
      gasPrice: 18000000000,
      url: `https://mainnet.infura.io/v3/${infuraKey}`,
      accounts: [privateKey],
      timeout: 20000,
    },
  },
  etherscan: {
    apiKey: {
      sepolia: ethereumApiKey,
    },
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: true,
    disambiguatePaths: false,
  },
  mocha: {
    timeout: 50000,
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
  }
};
export default config;
