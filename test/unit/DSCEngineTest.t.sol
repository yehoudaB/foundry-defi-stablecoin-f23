// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether; // $100

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokensAddresses;
    address[] public priceFeedsAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokensAddresses.push(weth);
        priceFeedsAddresses.push(ethUsdPriceFeed);
        priceFeedsAddresses.push(wbtcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeEqualLength.selector);
        new DSCEngine(tokensAddresses, priceFeedsAddresses, address(dsc));
    }

    ///////////////////////
    // Prices Test ////////
    ///////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000 (eth price in usd)  = 30,000e18
        uint256 expectedUsdAmount = 30_000e18;
        uint256 actualUsdAmount = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdAmount, actualUsdAmount);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100e18;
        // 100e18 / 2000 = 0.05e18
        uint256 expectedWethAmount = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWethAmount, actualWeth);
    }
    ////////////////////////////////////
    // Deposite collateral Test ////////
    ///////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositeCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeAllowedCollateral.selector);
        dscEngine.depositeCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateraAndGetAccountInfo() public depositeCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositedAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedAmount);
    }

    function testCannotMintDscIfCollateralIsBelowThreshold() public depositeCollateral {
        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 allowedAmountToBorrow =
            collateralValueInUsd * dscEngine.getLiquidationThreshold() / dscEngine.getLiquidationPrecision();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.mintDsc(allowedAmountToBorrow + 1 wei);
        vm.stopPrank();
    }

    function testCanMintDscIfCollateralIsAtThreshold() public depositeCollateral {
        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 allowedAmountToBorrow =
            collateralValueInUsd * dscEngine.getLiquidationThreshold() / dscEngine.getLiquidationPrecision();
        vm.startPrank(USER);
        dscEngine.mintDsc(allowedAmountToBorrow);
        vm.stopPrank();
    }

    function testUserCannotRedeemCollateralIfHealthFactorIsBelowThreshold() public depositeCollateral {
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        console.log("healthFactor", healthFactor);
        console.log("expectedHealthFactor", expectedHealthFactor);
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $150 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        // $180 collateral / 200 debt = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    modifier depositeCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositeCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositeCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }
}
