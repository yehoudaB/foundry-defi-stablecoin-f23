// SPDX-License-Identifier: MIT
// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

/*
 * @title DSCEngine
 * @author YehoudaB
 *  The syteme is designe to be as minimal as possible, and have the tokens maintain a 1:1 peg with the USD.
 * - Exogenous Collateral: WETH & WBTC
 * Our DSC system should be always "overcollateralized". At no point should the value of all collateral <= the $ backed value of all DSC.
 * - Dollar pegged
 * - Algorithmic Stable
 * It is similar to DAI if DAI had no governance, and was only backed by WETH and WBTC.
 * @notice This contract is the core of the DSC System. it handles all the logic for minting and redeeming DSC,
 * as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely base on the MakerDAO (DAI) system.
 *
 */

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    ////////////////////
    /// errors  ////
    //////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeEqualLength();
    error DSCEngine__MustBeAllowedCollateral();
    error DSCEngine__DepositeCollateralFailed();
    error DSCEngine__BreaksHealthFactor(uint256 _healthFactor);
    error DSCEngine__MintDscFailed();

    ////////////////////////
    /// State variables  //
    //////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECSION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MINIMUM_HEALTH_FACTOR = 1;
    mapping(address token => address priceFeed) private s_priceFeed;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    DecentralizedStableCoin private immutable i_dsc;
    address[] private s_collateralTokens;

    ////////////////////////
    /// events  ///////////
    //////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    ////////////////////
    /// modifiers  ////
    //////////////////

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedCollateral(address _tokenCollateralAddress) {
        if (s_priceFeed[_tokenCollateralAddress] == address(0)) {
            revert DSCEngine__MustBeAllowedCollateral();
        }
        _;
    }

    ////////////////////
    /// functions  ////
    //////////////////
    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dscAddress) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeEqualLength();
        }
        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeed[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    ///////////////////////////
    //// external functions //
    /////////////////////////

    /*
     * @param _tokenCollateralAddress the address of the token to deposite as collateral.
     * @param _amount The amount of collateral to  deposite.
     * @param _amountDscToMint The amount of Dsc to mint.
     * @notice this function will deposite collateral and mint DSC in one transaction.
     */
    function depositeCollateralAndMintDSC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositeCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    }

    /*
     * @notice Follows CEI pattern
     * @param _tokenCollateralAddress the address of the token to deposite as collateral.
     * @param _amount The amount of collateral to  deposite.
     */
    function depositeCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        isAllowedCollateral(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) {
            revert DSCEngine__DepositeCollateralFailed();
        }
    }

    function redeemCollateral(uint256 _amount) external {}

    /*
    * @notice Follows CEI pattern
    * @param _amount The amount of Dsc to mint.
    * @notic they must have more value than the minimum threshold.
    */
    function mintDsc(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorBelowThreshold(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintDscFailed();
        }
    }

    function redeemDSCAndWithdrawCollateral(uint256 _amount) external {}

    function burnDSC(uint256 _amount) external {}

    function liquidate(address _user) external {}

    function getHealthFactor(address _user) external view returns (uint256) {}

    ///////////////////////////
    //// internal & private  functions //
    /////////////////////////

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[_user];
        collateralValueInUsd = getAccountCollateralValueInUsd(_user);
    }

    /*
    * @notice return how close to liquidation the user is.
    * if a user goes below 1, then it can be liquidated. 
    */
    function _healthFactor(address _user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        uint256 collateralAjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAjustedForThreshold * PRECSION) / totalDscMinted;
    }

    function _revertIfHealthFactorBelowThreshold(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MINIMUM_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////////////////////
    //// Public & External View functions ///
    ////////////////////////////////////////

    function getAccountCollateralValueInUsd(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECSION;
    }
}
