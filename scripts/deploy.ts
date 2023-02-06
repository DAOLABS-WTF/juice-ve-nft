import * as fs from 'fs';
import * as hre from 'hardhat';
import { deployRecordContract, getContractRecord, logger } from './lib/lib';

const parentDir = '../dl-jbx3'; // NOTE: this depends on the local machine, relative to execution dir

// const networkName = hre.network.name;
const networkName = 'goerli';

async function main() {
    const deploymentLogPath = `./deployments/${networkName}/ve.json`;
    if (!fs.existsSync(deploymentLogPath)) {
        fs.writeFileSync(deploymentLogPath, `{ "${networkName}": { }, "constants": { } }`);
    }

    logger.info(`deploying DAOLABS Juicebox v3, vote escrow, fork to ${networkName}`);

    const [deployer] = await hre.ethers.getSigners();
    logger.info(`connected as ${deployer.address}`);

    const jbOperatorStoreAddress = getContractRecord('JBOperatorStore', `${parentDir}/deployments/${networkName}/platform.json`, networkName).address;
    const jbProjectsAddress = getContractRecord('JBProjects', `${parentDir}/deployments/${networkName}/platform.json`, networkName).address;
    await deployRecordContract('JBVeNftDeployer', [
        jbOperatorStoreAddress,
        jbProjectsAddress
    ], deployer, 'JBVeNftDeployer', deploymentLogPath);

    logger.info('deployment complete');
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});

// npx hardhat run scripts/deploy.ts --network goerli
