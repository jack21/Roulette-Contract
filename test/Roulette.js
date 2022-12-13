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
  let betAmount;

  beforeEach(async () => {
    [owner, player] = await ethers.getSigners();
    ({ roulette, link, vRFV2Wrapper } = await loadFixture(deployFixture));
    betAmount = await roulette.betAmount();
  });

  it("check initial value after deploy", async () => {
    // verify
    expect(await roulette.betAmount()).to.equal(ethers.utils.parseEther("0.1"));
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
    it("bet with Bet event", async () => {
      await expect(roulette.connect(player).bet(0, 0, { value: betAmount })).to.emit(roulette, "Bet");
    });

    it("bet with return betId", async () => {
      const betId = await roulette.connect(player).callStatic.bet(0, 0, { value: betAmount });
      // verify
      expect(betId).to.equal(1);
    });

    it("bet", async () => {
      const { requestId, betId } = await bet(1, 1);
      const latestBlock = await hre.ethers.provider.getBlock("latest");
      // verify
      // BetInfo
      const betInfo = await roulette.getBetInfo(1);
      expect(betInfo.betId).to.equal(betId);
      expect(betInfo.player).to.equal(player.address);
      expect(betInfo.amount).to.equal(betAmount);
      expect(betInfo.randomNumber).to.equal(0);
      expect(betInfo.rewardAmount).to.equal(0);
      expect(betInfo.betType).to.equal(1);
      expect(betInfo.betNumber).to.equal(1);
      expect(betInfo.betTimestamp).to.equal(latestBlock.timestamp);
      expect(betInfo.isDraw).to.equal(false);
      expect(betInfo.isWin).to.equal(false);
      expect(betInfo.isClaimed).to.equal(false);
      // getplayerBetIds
      const playerBetIds = await roulette.getPlayerBetIds(player.address);
      expect(playerBetIds.length).to.equal(1);
      // BetIds
      const playerBetsBetId = await roulette.playerBets(player.address, 0);
      expect(playerBetsBetId).to.equal(betId);
    });
  });

  it("fulfillRandomWords with right event", async () => {
    const { requestId, betId } = await bet(0, 1); // RED
    // verify
    const randomNumber = 12345;
    await expect(vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [randomNumber]))
      .to.emit(roulette, "ChainLinkRandomNumber")
      .withArgs(requestId, betId, randomNumber % 36);
  });

  describe("Bet result", () => {
    let requestId, betId;
    describe("Bet COLOR result", () => {
      beforeEach(async () => {
        ({ requestId, betId } = await bet(0, 1)); // RED
      });

      it("win with right reward", async () => {
        await win(101, 2);
      });

      it("lose with right result", async () => {
        await lose(100);
      });
    });

    describe("Bet COLUMN result", () => {
      beforeEach(async () => {
        ({ requestId, betId } = await bet(1, 1)); // 2ND
      });

      it("win with right reward", async () => {
        await win(100, 3);
      });

      it("lose with right result", async () => {
        await lose(101);
      });
    });

    describe("Bet DOZEN result", () => {
      beforeEach(async () => {
        ({ requestId, betId } = await bet(2, 2)); // 25-36
      });

      it("win with right reward", async () => {
        await win(25, 3);
      });

      it("lose with right result", async () => {
        await lose(24);
      });
    });

    describe("Bet EIGHTEEN result", () => {
      beforeEach(async () => {
        ({ requestId, betId } = await bet(3, 1)); // 19-36
      });

      it("win with right reward", async () => {
        await win(19, 2);
      });

      it("lose with right result", async () => {
        await lose(18);
      });
    });

    describe("Bet MODULUSmodulus result", () => {
      beforeEach(async () => {
        ({ requestId, betId } = await bet(4, 0)); // EVEN
      });

      it("win with right reward", async () => {
        await win(200000000, 2);
      });

      it("lose with right result", async () => {
        await lose(1);
      });
    });

    const win = async (randomNumber, payout) => {
      await vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [randomNumber]);
      const betInfo = await roulette.getBetInfo(betId);
      expect(betInfo.randomNumber).to.equal(randomNumber % 36);
      expect(betInfo.rewardAmount).to.equal(betAmount.mul(payout));
      expect(betInfo.isDraw).to.equal(true);
      expect(betInfo.isWin).to.equal(true);
      expect(betInfo.isClaimed).to.equal(false);
    };

    const lose = async (randomNumber) => {
      await vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [randomNumber]);
      const betInfo = await roulette.getBetInfo(betId);
      expect(betInfo.randomNumber).to.equal(randomNumber % 36);
      expect(betInfo.rewardAmount).to.equal(0);
      expect(betInfo.isDraw).to.equal(true);
      expect(betInfo.isWin).to.equal(false);
      expect(betInfo.isClaimed).to.equal(false);
    };
  });

  describe("Claim", () => {
    it("claim but betId not exist", async () => {
      const { requestId, betId } = await bet(4, 0); // EVEN
      await vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [11]);
      await expect(roulette.connect(player).claim([10000000])).revertedWith("!betInfo");
    });

    it("claim but player not match", async () => {
      const { requestId, betId } = await bet(4, 0); // EVEN
      await vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [11]);
      await expect(roulette.connect(owner).claim([betId])).revertedWith("!player");
    });

    it("claim but not draw", async () => {
      const { requestId, betId } = await bet(4, 0); // EVEN
      await expect(roulette.connect(player).claim([betId])).revertedWith("!draw");
    });

    it("claim with lose betId", async () => {
      const { requestId, betId } = await bet(4, 0); // EVEN
      await vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [11]);
      await expect(roulette.connect(player).claim([betId])).revertedWith("!win");
    });

    it("claim but ETH not enough", async () => {
      const { requestId, betId } = await bet(4, 0); // EVEN
      await vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [10]);
      await expect(roulette.connect(player).claim([betId])).revertedWith("ETH not enough");
    });

    describe("Claim Success", () => {
      beforeEach(async () => {
        // give some ETH
        await owner.sendTransaction({ to: roulette.address, value: ethers.utils.parseEther("10") });
      });

      it("claim success with Claim event", async () => {
        // bet
        const { requestId, betId } = await bet(4, 0); // EVEN
        await vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [10]);
        // verify
        const betInfo = await roulette.getBetInfo(betId);
        await expect(roulette.connect(player).claim([betId]))
          .to.emit(roulette, "Claim")
          .withArgs(player.address, betId, betInfo.rewardAmount)
          .changeEtherBalance(player, betInfo.rewardAmount)
          .changeEtherBalance(roulette.address, betInfo.rewardAmount.mul(-1));
      });

      it("re-claim", async () => {
        const { requestId, betId } = await bet(4, 0); // EVEN
        await vRFV2Wrapper.rawFulfillRandomWords(roulette.address, requestId, [10]);
        await roulette.connect(player).claim([betId]);
        await expect(roulette.connect(player).claim([betId])).revertedWith("claimed");
      });
    });
  });

  const bet = async (betType, betNumber) => {
    // bet
    const tx = await roulette.connect(player).bet(betType, betNumber, { value: betAmount });
    // requestId
    const receipt = await tx.wait();
    const betEvent = receipt.events?.find((x) => x.event == "Bet");
    const requestId = betEvent?.args.requestId;
    const betId = await roulette.lastBetId();
    return { requestId, betId };
  };
});
