require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();
require("hardhat-abi-exporter");
require("@nomiclabs/hardhat-etherscan");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.17",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      chainId: 1337,
      allowUnlimitedContractSize: true,
      gas: 6000000,
    },
    // 指令 npx hardhat run --network goerli scripts/deploy.js
    goerli: {
      url: process.env.RCP_GOERLI_URL,
      accounts: [process.env.PRIVATE_KEY],
      gas: 6000000,
    },
    // 指令 npx hardhat run --network mumbai scripts/deploy.js
    mumbai: {
      url: process.env.RPC_MUMBAI_URL,
      accounts: [process.env.PRIVATE_KEY],
      gas: 6000000,
    },
  },
  mocha: {
    timeout: 20000,
  },
  // 指令 npx hardhat verify --network goerli <合約地址> "0xD4a33860578De61DBAbDc8BFdb98FD742fA7028e"
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  // 指令 npx hardhat export-abi
  abiExporter: {},
};
