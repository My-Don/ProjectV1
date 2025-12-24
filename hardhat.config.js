require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades"); 
require("dotenv").config();


// 配置hardhat accounts参数
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.0",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
          viaIR: true
        }
      },
       {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
          viaIR: true
        }
      },
      {
        version: "0.6.6",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.6.2",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
       {
        version: "0.5.17",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.5.16",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.5.0",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.4.19",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      }
    ]
  },
  networks: {
    mainnet: {
      url: process.env.MAINNET_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: 1
    },
    sepolia: {
      url: process.env.SEPOLIA_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: 11155111,
       // 增加超时时间，防止网络问题
      timeout: 120000, // 120秒
      gasPrice: "auto"
    },
    bscTestnet: {
      url: process.env.BSCTEST_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: 97
    },
    bsc: {
      url: process.env.BSCMAINNET_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: 56
    },
    local: {
      url: process.env.LOCAL_URL || "",
      accounts: process.env.LOCAL_PRIVATE_KEY !== undefined ? [process.env.LOCAL_PRIVATE_KEY] : []
    },
    monadTestnet: {
      url: process.env.MONAD_TESTNET_RPC_URL,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: 10143
    },
    monadMainnet: {
      url: process.env.MONAD_MAINNET_RPC_URL,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: 143
    },

  },
 etherscan: {
  enabled: true,
    apiKey: {
      monadMainnet: process.env.ETHERSCAN_API_KEY,
      monadTestnet: process.env.ETHERSCAN_API_KEY,
      bsc: process.env.BSCSCAN_API_KEY,
      bscTestnet: process.env.BSCSCAN_API_KEY,
      sepolia: process.env.ETHERSCAN_API_KEY
    },
    customChains: [
      {
        network: "monadTestnet",
        chainId: 10143,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=10143", 
          browserURL: "https://testnet.monadscan.com"
        }
      },
       {
        network: "monadMainnet",
        chainId: 143,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=143", 
          browserURL: "https://monadscan.com"
        }
      },
      {
        network: "bscTestnet",
        chainId: 97,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=97", 
          browserURL: "https://testnet.bscscan.com"
        }
      },
      {
        network: "bsc",
        chainId: 56,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=56", 
          browserURL: "https://bscscan.com"
        }
      }
    ]
  },
  // 覆盖率配置
  coverage: {
    enabled: true,
    exclude: ['test/', 'node_modules/', 'coverage/', 'scripts/'],
    reporter: ['html', 'lcov', 'text', 'json'],
    solcoverjs: './.solcover.js',
  },
  mocha: {
    timeout: 40000
  },
  sourcify: {
    enabled: false,
    apiUrl: "https://sourcify-api-monad.blockvision.org/",
    browserUrl: "https://monadvision.com"
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  }
};
