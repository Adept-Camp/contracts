usePlugin("@nomiclabs/buidler-truffle5");
usePlugin("solidity-coverage");
usePlugin("buidler-gas-reporter");

module.exports = {
  defaultNetwork: "buidlerevm",
  networks: {
    buidlerevm: {
      gas: 95000000,
      blockGasLimit: 95000000,
    },
  },
  solc: {
    version: "0.5.17",
    optimizer: {
      enabled: true,
      runs: 200,
    },
    evmVersion: "constantinople",
  },
};
