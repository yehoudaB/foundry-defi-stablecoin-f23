// SPDX-LICENSE-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Invariant is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    Handler handler;
    HelperConfig config;
    address ethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;

    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether; // $100
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));
        uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);
        console.log("totalSupply: %s", totalSupply);
        console.log("weth value: %s", wethValue);
        console.log("wbtc value: %s", wbtcValue);
        console.log("times mint called %s", handler.timesMintIsCalled());
        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNeverRevert() public view {
        dscEngine.getAccountCollateralValueInUsd(msg.sender);
        dscEngine.getAccountInformation(msg.sender);
        dscEngine.getCollateralBalanceOfUser(msg.sender, weth);
        dscEngine.getCollateralBalanceOfUser(msg.sender, wbtc);
        dscEngine.getCollateralTokens();
        dscEngine.getUsdValue(weth, 1 ether);
        dscEngine.getUsdValue(wbtc, 1 ether);
        dscEngine.getCollateralDeposited(weth, msg.sender);
        dscEngine.getCollateralDeposited(wbtc, msg.sender);
        dscEngine.getLiquidationThreshold();
        dscEngine.getLiquidationBonus();
        dscEngine.getLiquidationPrecision();
        dscEngine.getDscMinted(msg.sender);
        dscEngine.getHealthFactor(msg.sender);
        dscEngine.getTokenAmountFromUsd(weth, 1 ether);
        dscEngine.getTokenAmountFromUsd(wbtc, 1 ether);
    }
}
