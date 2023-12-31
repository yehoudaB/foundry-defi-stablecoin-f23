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
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether; // $100
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;

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

    function testCannotMintMoreDscThanCollateralValue() public depositeCollateral {
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

    ////////////////////
    // burnDsc Tests //
    //////////////////

    function testRevertsIfBurnAmountIsZero() public giveApprovals {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.burnDSC(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public depositedCollateralAndMintedDsc giveApprovals {
        uint256 dscToBurn = 101 ether;
        console.log("dscToBurn", dscToBurn);
        console.log("dsc.balanceOf(USER)", dsc.balanceOf(USER));
        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.burnDSC(dscToBurn);
        vm.stopPrank();
    }

    function testCanBurnDscIfHasDsc() public depositedCollateralAndMintedDsc giveApprovals {
        vm.startPrank(USER);
        dscEngine.burnDSC(AMOUNT_TO_MINT);
        vm.stopPrank();
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }
    ////////////////////////////////
    // redeemCollateral Tests /////
    //////////////////////////////

    function testUserCannotRedeemCollateralIfHealthFactorIsBelowThreshold() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsReedemCollateralIfNotEnoughCollateral() public {
        vm.startPrank(USER);
        vm.expectRevert(); // Arithmetic over/underflow
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfAmountToRedeemIsZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateralPartially() public depositedCollateralAndMintedDsc {
        uint256 collateralToRedeem = 5 ether;
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, collateralToRedeem);
        vm.stopPrank();
        uint256 collateralDeposited = dscEngine.getCollateralDeposited(weth, USER);
        assertEq(collateralDeposited, AMOUNT_COLLATERAL - collateralToRedeem);
    }

    function testCanReedemAllCollateral() public depositeCollateral {
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralDeposited = dscEngine.getCollateralDeposited(weth, USER);
        assertEq(collateralDeposited, 0);
    }

    function testRedeemSpecificAmount() public depositeCollateral {
        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, 256749829215);
        ERC20Mock(weth).approve(address(dscEngine), 256749829215);
        dscEngine.depositeCollateral(weth, 256749829215);
        dscEngine.redeemCollateral(weth, 256749829215);
        vm.stopPrank();
    }

    ////////////////////////
    // liquidation Tests //
    ////////////////////////

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositeCollateralAndMintDSC(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testCanLiquidateUserIfHealthFactorIsBelowThreshold() public liquidated {
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        console.log("userHealthFactor", userHealthFactor);
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositeCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositeCollateralAndMintDSC(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        uint256 liquidatorHealthFactor = dscEngine.getHealthFactor(LIQUIDATOR);
        console.log("user", USER, "Liquidator", LIQUIDATOR);
        dscEngine.liquidate(USER, weth, AMOUNT_TO_MINT); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) / dscEngine.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) / dscEngine.getLiquidationBonus());

        uint256 usdAmountLiquidated = dscEngine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd =
            dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70000000000000000020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, AMOUNT_TO_MINT);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
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
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc healthFactorGoBelowOne {
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        console.log("userHealthFactor", userHealthFactor);
        assert(userHealthFactor == 0.9 ether);
    }

    modifier healthFactorGoBelowOne() {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $20O at all times if we have $100 of debt
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) = 0.9

        _;
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

    modifier giveApprovals() {
        vm.startPrank(USER);
        uint256 wEthDeposited = dscEngine.getCollateralDeposited(weth, USER);
        uint256 wBtcDeposited = dscEngine.getCollateralDeposited(wbtc, USER);
        uint256 dscMinted = dscEngine.getDscMinted(USER);

        ERC20Mock(weth).approve(address(dscEngine), wEthDeposited);
        ERC20Mock(wbtc).approve(address(dscEngine), wBtcDeposited);
        dsc.approve(address(dscEngine), dscMinted);
        vm.stopPrank();
        _;
    }
}
