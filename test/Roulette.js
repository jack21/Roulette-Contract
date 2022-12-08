const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Roulette", function () {
  async function deployFixture() {
    // Chainlink Mock
    const MockLINK = await ethers.getContractFactory("MockLINK");
    const link = await MockLINK.deploy();
    await link.deployed();
    const MockVRFV2Wrapper = await ethers.getContractFactory("MockVRFV2Wrapper");
    const vRFV2Wrapper = await MockVRFV2Wrapper.deploy();
    await vRFV2Wrapper.deployed();

    // contract
    const Roulette = await ethers.getContractFactory("Roulette");
    const roulette = await Roulette.deploy(link.address, vRFV2Wrapper.address);
    await roulette.deployed();

    return { roulette, link, vRFV2Wrapper };
  }

  let owner, player;
  let roulette, link, vRFV2Wrapper;

  beforeEach(async () => {
    [owner, player] = await ethers.getSigners();
    ({ roulette, link, vRFV2Wrapper } = await loadFixture(deployFixture));
  });

  it("check initial value after deploy", async function () {
    // verify
    expect(await roulette.betAmount()).to.equal(ethers.utils.parseEther("0.001"));
    expect(await roulette.payouts(0)).to.eql(2);
    expect(await roulette.payouts(1)).to.eql(3);
    expect(await roulette.payouts(2)).to.eql(3);
    expect(await roulette.payouts(3)).to.eql(2);
    expect(await roulette.payouts(4)).to.eql(2);
    expect(await roulette.payouts(5)).to.eql(36);
    expect(await roulette.numberRange(0)).to.eql(1);
    expect(await roulette.numberRange(1)).to.eql(2);
    expect(await roulette.numberRange(2)).to.eql(2);
    expect(await roulette.numberRange(3)).to.eql(1);
    expect(await roulette.numberRange(4)).to.eql(1);
    expect(await roulette.numberRange(5)).to.eql(36);
  });

  describe("Bet", () => {
    it("bet with Bet event", async function () {
      const betAmount = await roulette.betAmount();
      await expect(roulette.connect(player).bet(0, 0, { value: betAmount })).to.emit(roulette, "Bet");
    });

    it("bet with return betId", async function () {
      const betAmount = await roulette.betAmount();
      const betId = await roulette.connect(player).callStatic.bet(0, 0, { value: betAmount });
      // verify
      expect(betId).to.equal(1);
    });

    it("bet", async function () {
      const betAmount = await roulette.betAmount();
      await roulette.connect(player).bet(0, 0, { value: betAmount });
      // verify
      const lastBetId = await roulette.lastBetId();
      // BetInfo
      const betInfo = await roulette.getBetInfo(1);
      expect(betInfo.player).to.equal(player.address);
      expect(betInfo.betId).to.equal(lastBetId);
      expect(betInfo.amount).to.equal(betAmount);
      expect(betInfo.betType).to.equal(0);
      expect(betInfo.betNumber).to.equal(0);
      expect(betInfo.isOpen).to.equal(false);
      expect(betInfo.isWin).to.equal(false);
      // getplayerBetIds
      const playerBetIds = await roulette.getPlayerBetIds(player.address);
      expect(playerBetIds.length).to.equal(1);
      // BetIds
      const playerBetsBetId = await roulette.playerBets(player.address, 0);
      expect(playerBetsBetId).to.equal(lastBetId);
    });
  });

  it("fulfillRandomWords", async function () {
    // bet
    const betAmount = await roulette.betAmount();
    const tx = await roulette.connect(player).bet(0, 1, { value: betAmount });
    // requestId
    const receipt = await tx.wait();
    const betEvent = receipt.events?.find((x) => x.event == "Bet");
    const requestId = betEvent?.args.requestId;
    // console.log(requestId);
    const lastBetId = await roulette.lastBetId();
    // verify
    const randomNumber = 12345;
    await expect(vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [randomNumber]))
      .to.emit(roulette, "ChainLinkRandomNumber")
      .withArgs(requestId, lastBetId, randomNumber % 37);
  });
});
