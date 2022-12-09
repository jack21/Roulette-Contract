const hre = require("hardhat");
const { ethers } = hre;

// Chainlink supported networks https://docs.chain.link/vrf/v2/direct-funding/supported-networks
const LINK_TOKEN = "0x326C977E6efc84E512bB9C30f76E30c160eD06FB"; // goerli & mumbai
const VRF_WRAPPER_GOERLI = "0x708701a1DfF4f478de54383E49a627eD4852C816"; // goerli
const VRF_WRAPPER_MUMBAI = "0x99aFAf084eBA697E584501b8Ed2c0B37Dd136693"; // mumbai

async function main() {
  const { chainId } = await ethers.provider.getNetwork();

  let VRF_WRAPPER;
  let scanURL;
  if (chainId === 80001) {
    // mumbai
    console.log(`Mumbai, ChainId: ${chainId}`);
    VRF_WRAPPER = VRF_WRAPPER_MUMBAI;
    scanURL = "https://mumbai.polygonscan.com/address/";
  } else if (chainId === 5) {
    // goerli
    console.log(`Goerli, ChainId: ${chainId}`);
    VRF_WRAPPER = VRF_WRAPPER_GOERLI;
    scanURL = "https://goerli.etherscan.io/address/";
  }

  // prepare
  const link = await ethers.getContractAt("MockLINK", LINK_TOKEN);
  const vRFV2Wrapper = await ethers.getContractAt("MockVRFV2Wrapper", VRF_WRAPPER);

  // deploy
  const Roulette = await ethers.getContractFactory("Roulette");
  const roulette = await Roulette.deploy(link.address, vRFV2Wrapper.address);
  await roulette.deployed();

  // fund contract
  await link.transfer(roulette.address, ethers.utils.parseEther("2"));

  console.log(`\nRoulette deployed to ${roulette.address}`);
  console.log(`${scanURL}${roulette.address}`);

  // test bet
  try {
    const tx = await roulette.bet(0, 0, { value: ethers.utils.parseEther("0.001") });
    // const receipt = await tx.wait();
    console.log("\nTest Bet Complete");
    await roulette.withdrawLink();
  } catch (e) {
    console.error("\nTest Bet Exception\n", e);
    await roulette.withdrawLink();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
