import * as dotenv from 'dotenv';
import { task, subtask } from 'hardhat/config';
import fs from 'fs';

import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from 'hardhat/builtin-tasks/task-names';

// import '@ethereum-waffle/chai';
// import '@nomicfoundation/hardhat-chai-matchers';
import "@nomiclabs/hardhat-ethers";
import '@nomiclabs/hardhat-etherscan';
// import '@nomiclabs/hardhat-waffle';
import '@typechain/hardhat';
import 'hardhat-contract-sizer';
import 'hardhat-deploy';
import 'hardhat-gas-reporter';
// import 'solidity-coverage';

dotenv.config();

const INFURA_API_KEY = process.env.INFURA_API_KEY;
const ALCHEMY_MAINNET_URL = process.env.ALCHEMY_MAINNET_URL;
const ALCHEMY_MAINNET_KEY = process.env.ALCHEMY_MAINNET_API_KEY;
const REPORT_GAS = process.env.REPORT_GAS;
const COINMARKETCAP_KEY = process.env.COINMARKETCAP_API_KEY;
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY;
const PRIVATE_KEY = process.env.PRIVATE_KEY;

type ProviderNetwork = 'localhost' | 'hardhat';

const defaultNetwork: ProviderNetwork = 'hardhat';

function accountSeed() {
    if (PRIVATE_KEY !== undefined) {
        return [PRIVATE_KEY];
    } else if (fs.existsSync('./mnemonic.txt')) {
        return { mnemonic: fs.readFileSync('./mnemonic.txt').toString().trim() };
    } else if (defaultNetwork !== 'localhost') {
        console.log('☢️ WARNING: No mnemonic file created for a deploy account.');
    }

    return { mnemonic: '' };
}

const infuraId = process.env.INFURA_ID || INFURA_API_KEY;

module.exports = {
    defaultNetwork,
    networks: {
        hardhat: {
            // forking: {
            //     url: `${ALCHEMY_MAINNET_URL}/${ALCHEMY_MAINNET_KEY}`,
            //     blockNumber: 15416229,
            //     enabled: false
            // },
            forking: {
                url: 'https://goerli.infura.io/v3/' + infuraId,
                blockNumber: 8219039,
                enabled: true
            },
            allowUnlimitedContractSize: true,
            blockGasLimit: 100_000_000
        },
        localhost: {
            url: 'http://localhost:8545',
            blockGasLimit: 0x1fffffffffffff,
        },
        goerli: {
            url: 'https://goerli.infura.io/v3/' + infuraId,
            accounts: accountSeed()
        },
        mainnet: {
            url: 'https://mainnet.infura.io/v3/' + infuraId,
            accounts: accountSeed()
        },
    },
    namedAccounts: {
        deployer: {
            default: 0,
        },
        feeCollector: {
            default: 0,
        },
    },
    solidity: {
        version: '0.8.16',
        settings: {
            optimizer: {
                enabled: true,
                runs: 400,
            },
        },
    },
    contractSizer: {
        alphaSort: true,
        disambiguatePaths: false,
        runOnCompile: true,
        strict: false
    },
    gasReporter: {
        enabled: REPORT_GAS !== undefined,
        currency: 'USD',
        gasPrice: 30,
        showTimeSpent: true,
        coinmarketcap: COINMARKETCAP_KEY
    },
    etherscan: {
        apiKey: ETHERSCAN_API_KEY
    },
    mocha: {
        timeout: 30 * 60 * 1000,
        bail: false
    },
    docgen: {}
};

task('deploy-ballot', 'Deploy a buffer ballot of a given duration')
    .addParam('duration', 'Set the ballot duration (in seconds)')
    .setAction(async (taskArgs, hre) => {
        try {
            const { deploy } = hre.deployments;
            const [deployer] = await hre.ethers.getSigners();

            const JBReconfigurationBufferBallot = await deploy('JBReconfigurationBufferBallot', {
                from: deployer.address,
                log: true,
                args: [taskArgs.duration],
            });

            console.log('Buffer ballot deployed at ' + JBReconfigurationBufferBallot.address);
        } catch (error) {
            console.log(error);
        }
    });


subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS)
    .setAction(async (_, __, runSuper) => {
        const paths = await runSuper();

        return paths.filter((p: string) => !p.includes('forge-test')).filter((p: string) => !p.endsWith('s.sol'));
    });
