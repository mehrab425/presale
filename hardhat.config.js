require('dotenv').config();
require("@nomiclabs/hardhat-ethers");

module.exports = {
  solidity: "0.8.9",
  networks: {
    local: {
      url: "http://127.0.0.1:8545"
    },
    mynet: {
      url: process.env.RPC_URL,         // URL نود/endpoint شبکه‌ات
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : []
    }
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || ""
  }
};
