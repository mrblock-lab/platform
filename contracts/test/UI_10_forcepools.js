// const { BN, constants, expectEvent, expectRevert, time } = require('openzeppelin-test-helpers');
const { BN, time } = require('openzeppelin-test-helpers');
var jsonfile = require('jsonfile');
var contractList = jsonfile.readFileSync('./contracts.json');

const Booster = artifacts.require("Booster");
const ICurveGauge = artifacts.require("ICurveGauge");
const CrvDepositor = artifacts.require("CrvDepositor");
const ConvexToken = artifacts.require("ConvexToken");
const cvxCrvToken = artifacts.require("cvxCrvToken");
const CurveVoterProxy = artifacts.require("CurveVoterProxy");
const BaseRewardPool = artifacts.require("BaseRewardPool");
const IERC20 = artifacts.require("IERC20");
const CvxCrvStakingWrapper = artifacts.require("CvxCrvStakingWrapper");
const ExtraRewardStashV3 = artifacts.require("ExtraRewardStashV3");
const BoosterOwner = artifacts.require("BoosterOwner");
const StashTokenWrapper = artifacts.require("StashTokenWrapper");
const VirtualBalanceRewardPool = artifacts.require("VirtualBalanceRewardPool");
const PoolManagerV4 = artifacts.require("PoolManagerV4");
const DepositToken = artifacts.require("DepositToken");

const unlockAccount = async (address) => {
  let NETWORK = config.network;
  if(!NETWORK.includes("debug")){
    return null;
  }
  return new Promise((resolve, reject) => {
    web3.currentProvider.send(
      {
        jsonrpc: "2.0",
        method: "hardhat_impersonateAccount",
        params: [address],
        id: new Date().getTime(),
      },
      (err, result) => {
        if (err) {
          return reject(err);
        }
        return resolve(result);
      }
    );
  });
};

const setNoGas = async () => {
  let NETWORK = config.network;
  if(!NETWORK.includes("debug")){
    return null;
  }
  return new Promise((resolve, reject) => {
    web3.currentProvider.send(
      {
        jsonrpc: "2.0",
        method: "hardhat_setNextBlockBaseFeePerGas",
        params: ["0x0"],
        id: new Date().getTime(),
      },
      (err, result) => {
        if (err) {
          return reject(err);
        }
        return resolve(result);
      }
    );
  });
};

const send = payload => {
  if (!payload.jsonrpc) payload.jsonrpc = '2.0';
  if (!payload.id) payload.id = new Date().getTime();

  return new Promise((resolve, reject) => {
    web3.currentProvider.send(payload, (error, result) => {
      if (error) return reject(error);

      return resolve(result);
    });
  });
};

/**
 *  Mines a single block in Ganache (evm_mine is non-standard)
 */
const mineBlock = () => send({ method: 'evm_mine' });

/**
 *  Gets the time of the last block.
 */
const currentTime = async () => {
  const { timestamp } = await web3.eth.getBlock('latest');
  return timestamp;
};

/**
 *  Increases the time in the EVM.
 *  @param seconds Number of seconds to increase the time by
 */
const fastForward = async seconds => {
  // It's handy to be able to be able to pass big numbers in as we can just
  // query them from the contract, then send them back. If not changed to
  // a number, this causes much larger fast forwards than expected without error.
  if (BN.isBN(seconds)) seconds = seconds.toNumber();

  // And same with strings.
  if (typeof seconds === 'string') seconds = parseFloat(seconds);

  await send({
    method: 'evm_increaseTime',
    params: [seconds],
  });

  await mineBlock();
};

contract("Test new pools", async accounts => {
  it("should complete without errors", async () => {

    let deployer = "0x947B7742C403f20e5FaCcDAc5E092C943E7D0277";
    await unlockAccount(deployer);
    let multisig = "0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB";
    await unlockAccount(multisig);
    let addressZero = "0x0000000000000000000000000000000000000000"

    let treasury = contractList.system.treasury;
    await unlockAccount(treasury);

    //system
    let booster = await Booster.at(contractList.system.booster);
    let voteproxy = await CurveVoterProxy.at(contractList.system.voteProxy);
    let crvDeposit = await CrvDepositor.at(contractList.system.crvDepositor);
    let vanillacvxCrv = await BaseRewardPool.at(contractList.system.cvxCrvRewards);
    let cvx = await ConvexToken.at(contractList.system.cvx);
    let crv = await IERC20.at("0xD533a949740bb3306d119CC777fa900bA034cd52");
    let threeCrv = await IERC20.at("0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490");
    let cvxCrv = await IERC20.at("0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7");
    let userA = accounts[0];
    let userB = accounts[1];
    let userC = accounts[2];
    let userD = accounts[3];
    let userZ = "0xAAc0aa431c237C2C0B5f041c8e59B3f1a43aC78F";
    var userNames = {};
    userNames[userA] = "A";
    userNames[userB] = "B";
    userNames[userC] = "C";
    userNames[userD] = "D";
    userNames[userZ] = "Z";

    const advanceTime = async (secondsElaspse) => {
      await fastForward(secondsElaspse);
      console.log("\n  >>>>  advance time " +(secondsElaspse/86400) +" days  >>>>\n");
    }
    const day = 86400;

    var pmanager = await booster.poolManager();
    await unlockAccount(pmanager);

    await setNoGas();
    var gauge = await ICurveGauge.at("0x222D910ef37C06774E1eDB9DC9459664f73776f0");
    var lptoken = await gauge.lp_token();
    await setNoGas();
    await booster.addPool(lptoken,gauge.address,3,{from:pmanager,gasPrice:0})
    console.log("pool added")

    var gauge = await ICurveGauge.at("0x1Cfabd1937e75E40Fa06B650CB0C8CD233D65C20");
    var lptoken = await gauge.lp_token();
    await setNoGas();
    await booster.addPool(lptoken,gauge.address,3,{from:pmanager,gasPrice:0})
    console.log("pool added")

    var gauge = await ICurveGauge.at("0x41eBf0bEC45642A675e8b7536A2cE9c078A814B4");
    var lptoken = await gauge.lp_token();
    await setNoGas();
    await booster.addPool(lptoken,gauge.address,3,{from:pmanager,gasPrice:0})
    console.log("pool added")

    var gauge = await ICurveGauge.at("0x49887dF6fE905663CDB46c616BfBfBB50e85a265");
    var lptoken = await gauge.lp_token();
    await setNoGas();
    await booster.addPool(lptoken,gauge.address,3,{from:pmanager,gasPrice:0})
    console.log("pool added")

    var gauge = await ICurveGauge.at("0x99440E11485Fc623c7A9F2064B97A961a440246b");
    var lptoken = await gauge.lp_token();
    await setNoGas();
    await booster.addPool(lptoken,gauge.address,3,{from:pmanager,gasPrice:0})
    console.log("pool added")

  });
});


