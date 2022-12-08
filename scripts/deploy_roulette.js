const { ethers } = require("hardhat");

// Chainlink supported networks https://docs.chain.link/vrf/v2/direct-funding/supported-networks
// const LINK_TOKEN = "0x326C977E6efc84E512bB9C30f76E30c160eD06FB"; // goerli
// const VRF_WRAPPER = "0x708701a1DfF4f478de54383E49a627eD4852C816"; // goerli
const LINK_TOKEN = "0x326C977E6efc84E512bB9C30f76E30c160eD06FB"; // mumbai
const VRF_WRAPPER = "0x99aFAf084eBA697E584501b8Ed2c0B37Dd136693"; // mumbai

async function main() {
  const link = await ethers.getContractAt("MockLINK", LINK_TOKEN);
  const vRFV2Wrapper = await ethers.getContractAt("MockVRFV2Wrapper", VRF_WRAPPER);

  const Roulette = await ethers.getContractFactory("Roulette");
  const roulette = await Roulette.deploy(link.address, vRFV2Wrapper.address);
  await roulette.deployed();

  // Fund contract
  await link.transfer(roulette.address, ethers.utils.parseEther("0.1"));

  console.log(`\nRoulette deployed to ${roulette.address}`);
  // console.log(`https://goerli.etherscan.io/address/${roulette.address}`);
  console.log(`https://mumbai.polygonscan.com/address/${roulette.address}`);

  const tx = await roulette.bet(0, 0, { value: ethers.utils.parseEther("0.001") });
  console.log("\nBet Complete", tx);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
