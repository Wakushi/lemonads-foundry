// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract Lemonads is FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    struct AdParcel {
        uint256 bid; // Current highest bid for the ad parcel
        uint256 minBid; // Minimum bid required for the ad parcel
        address owner; // Owner of the ad parcel
        address renter; // Current renter of the ad parcel
        string traitsHash; // IPFS hash for parcel metadata (width, fonts..)
        string contentHash; // IPFS hash for content
        string websiteInfoHash; // IPFS hash for website information
        bool active; // Is this parcel still active
    }

    struct ClickPerAd {
        uint256 adParcelId;
        uint256 clicks;
    }

    uint256 public constant MIN_CLICK_AMOUNT_COVERED = 10;

    uint256 public constant MIN_INTERVAL_BETWEEN_CRON = 1 days;

    // Mapping to store ad parcels by their ID
    mapping(uint256 adParcelId => AdParcel) private s_adParcels;

    // Mapping to store the aggregated amount of clicks per ad parcel
    mapping(uint256 adParcelId => uint256 clicks) private s_clickPerAdParcel;

    // Mapping from owner to array of owned parcel IDs
    mapping(address => uint256[]) private s_ownerParcels;

    // Mapping from renter to array of rented parcel IDs
    mapping(address => uint256[]) private s_renterParcels;

    // Mapping to store locked funds for each renter
    mapping(address => uint256) private s_renterFunds;

    // Global array to store all parcel IDs
    uint256[] private s_allParcels;

    // Parcel expecting payments
    uint256[] private s_payableParcels;

    // Chainlink Functions
    bytes32 s_donID;

    uint32 s_gasLimit = 300000;

    uint64 s_functionsSubId;

    string s_clickAggregatorSource;

    bytes32 s_lastRequestId;

    bytes32 s_lastRequestIdFulfilled;

    uint256 s_lastCronExecutionTime;

    error Lemonads__ParcelAlreadyCreatedAtId(uint256 parcelId);
    error Lemonads__ParcelNotFound();
    error Lemonads__UnsufficientFundsLocked();
    error Lemonads__NotZero();
    error Lemonads__TransferFailed();
    error Lemonads__BidLowerThanCurrent();
    error Lemonads__NotParcelOwner();
    error Lemonads__NotEnoughTimePassed();
    error Lemonads__NoPayableParcel();

    // Events
    event AdParcelCreated(
        uint256 indexed parcelId,
        address indexed owner,
        uint256 minBid
    );
    event MinBidUpdated(uint256 indexed parcelId, uint256 newMinBid);
    event TraitsUpdated(uint256 indexed parcelId, string traitsHash);
    event WebsiteInfoUpdated(uint256 indexed parcelId, string websiteInfoHash);
    event AdParcelRented(
        uint256 indexed parcelId,
        address indexed renter,
        uint256 bid
    );
    event FundsAdded(address indexed renter, uint256 amount);
    event FundsWithdrawn(address indexed renter, uint256 amount);
    event ChainlinkRequestSent(bytes32 requestId);
    event ClickAggregated(bytes32 requestId);
    event ParcelPaymentFailed(uint256 adParcelId);

    modifier onlyAdParcelOwner(uint256 _parcelId) {
        _ensureAdParcelOwnership(_parcelId);
        _;
    }

    constructor(
        address _functionsRouter,
        bytes32 _donId,
        uint64 _functionsSubId,
        string memory _clickAggregatorSource
    ) FunctionsClient(_functionsRouter) {
        s_donID = _donId;
        s_functionsSubId = _functionsSubId;
        s_clickAggregatorSource = _clickAggregatorSource;
    }

    // Function to create a new ad parcel
    function createAdParcel(
        uint256 _parcelId,
        uint256 _minBid,
        string calldata _traitsHash,
        string calldata _websiteInfoHash
    ) external {
        if (s_adParcels[_parcelId].owner != address(0)) {
            revert Lemonads__ParcelAlreadyCreatedAtId(_parcelId);
        }

        s_adParcels[_parcelId] = AdParcel({
            bid: 0,
            minBid: _minBid,
            owner: msg.sender,
            renter: address(0),
            active: true,
            traitsHash: _traitsHash,
            websiteInfoHash: _websiteInfoHash,
            contentHash: ""
        });

        s_ownerParcels[msg.sender].push(_parcelId);
        s_allParcels.push(_parcelId);

        emit AdParcelCreated(_parcelId, msg.sender, _minBid);
    }

    // Function to place a bid and rent an ad parcel
    function rentAdParcel(
        uint256 _parcelId,
        uint256 _newBid,
        string calldata _contentHash
    ) external payable {
        AdParcel storage adParcel = s_adParcels[_parcelId];

        if (adParcel.owner == address(0)) {
            revert Lemonads__ParcelNotFound();
        }

        if (_newBid < adParcel.bid) {
            revert Lemonads__BidLowerThanCurrent();
        }

        s_renterFunds[msg.sender] += msg.value;

        if (
            s_renterFunds[msg.sender] <
            (adParcel.bid * MIN_CLICK_AMOUNT_COVERED)
        ) {
            revert Lemonads__UnsufficientFundsLocked();
        }

        if (adParcel.renter != address(0)) {
            _removeAdRentedParcel(adParcel.renter, _parcelId);
        }

        adParcel.bid = _newBid;
        adParcel.renter = msg.sender;
        adParcel.contentHash = _contentHash;
        s_renterParcels[msg.sender].push(_parcelId);

        emit AdParcelRented(_parcelId, msg.sender, _newBid);
    }

    // Function to update the traits of an ad parcel
    function updateTraits(
        uint256 _parcelId,
        string calldata _traitsHash
    ) external onlyAdParcelOwner(_parcelId) {
        s_adParcels[_parcelId].traitsHash = _traitsHash;

        emit TraitsUpdated(_parcelId, _traitsHash);
    }

    // Function to update the website info of an ad parcel
    function updateWebsite(
        uint256 _parcelId,
        string calldata _websiteInfoHash
    ) external onlyAdParcelOwner(_parcelId) {
        s_adParcels[_parcelId].websiteInfoHash = _websiteInfoHash;

        emit WebsiteInfoUpdated(_parcelId, _websiteInfoHash);
    }

    // Function to update the minimum bid of an ad parcel
    function updateMinBid(
        uint256 _parcelId,
        uint256 _minBid
    ) external onlyAdParcelOwner(_parcelId) {
        s_adParcels[_parcelId].minBid = _minBid;

        emit MinBidUpdated(_parcelId, _minBid);
    }

    // Function to add funds to the renter's account
    function addFunds() external payable {
        if (msg.value == 0) {
            revert Lemonads__NotZero();
        }

        s_renterFunds[msg.sender] += msg.value;

        emit FundsAdded(msg.sender, msg.value);
    }

    // Function to withdraw funds from the renter's account
    function withdrawFunds(uint256 _amount) external {
        if (_amount > s_renterFunds[msg.sender]) {
            revert Lemonads__UnsufficientFundsLocked();
        }

        s_renterFunds[msg.sender] -= _amount;

        (bool success, ) = msg.sender.call{value: _amount}("");
        if (!success) {
            revert Lemonads__TransferFailed();
        }

        emit FundsWithdrawn(msg.sender, _amount);
    }

    function closeParcel(
        uint256 _parcelId
    ) external onlyAdParcelOwner(_parcelId) {
        AdParcel storage adParcel = s_adParcels[_parcelId];
        adParcel.active = false;
        adParcel.bid = 0;
        adParcel.renter = address(0);
        adParcel.websiteInfoHash = "";
    }

    function runClickAggregatorCron() external {
        if (
            block.timestamp <
            s_lastCronExecutionTime + MIN_INTERVAL_BETWEEN_CRON
        ) {
            revert Lemonads__NotEnoughTimePassed();
        }

        string[] memory requestArgs;

        requestArgs[0] = s_lastCronExecutionTime.toString();

        s_lastCronExecutionTime = block.timestamp;

        _generateSendRequest(requestArgs, s_clickAggregatorSource);
    }

    function payParcelOwners() external {
        if (s_payableParcels.length == 0) {
            revert Lemonads__NoPayableParcel();
        }

        uint256[] memory payableParcels = s_payableParcels;

        for (uint256 i = 0; i < payableParcels.length; i++) {
            uint256 adParcelId = payableParcels[i];

            uint256 clickAggregated = s_clickPerAdParcel[adParcelId];

            AdParcel storage adParcel = s_adParcels[adParcelId];

            uint256 amountDue = adParcel.bid * clickAggregated;

            s_clickPerAdParcel[adParcelId] = 0;

            (bool success, ) = adParcel.owner.call{value: amountDue}("");

            if (!success) {
                emit ParcelPaymentFailed(adParcelId);
            }
        }

        delete s_payableParcels;
    }

    ////////////////////
    // Internal
    ////////////////////

    function _generateSendRequest(
        string[] memory args,
        string memory source
    ) internal returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);
        req.secretsLocation = FunctionsRequest.Location.DONHosted;
        if (args.length > 0) {
            req.setArgs(args);
        }

        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            s_functionsSubId,
            s_gasLimit,
            s_donID
        );

        emit ChainlinkRequestSent(s_lastRequestId);
        return s_lastRequestId;
    }

    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        ClickPerAd[] memory clickPerAds = abi.decode(response, (ClickPerAd[]));

        for (uint256 i = 0; i < clickPerAds.length; i++) {
            uint256 adParcelId = clickPerAds[i].adParcelId;
            s_clickPerAdParcel[adParcelId] += clickPerAds[i].clicks;
            s_payableParcels.push(adParcelId);
        }

        s_lastRequestIdFulfilled = requestId;
        emit ClickAggregated(requestId);
    }

    // Internal function to remove a parcel from the renter's list
    function _removeAdRentedParcel(
        address _renter,
        uint256 _parcelId
    ) internal {
        uint256[] storage parcels = s_renterParcels[_renter];
        for (uint256 i = 0; i < parcels.length; i++) {
            if (parcels[i] == _parcelId) {
                parcels[i] = parcels[parcels.length - 1];
                parcels.pop();
                break;
            }
        }
    }

    function _ensureAdParcelOwnership(uint256 _parcelId) internal view {
        if (s_adParcels[_parcelId].owner != msg.sender) {
            revert Lemonads__NotParcelOwner();
        }
    }

    function getAdParcelById(
        uint256 _parcelId
    ) external view returns (AdParcel memory) {
        return s_adParcels[_parcelId];
    }

    // Function to get all parcels owned by a user
    function getOwnerParcels(
        address _owner
    ) external view returns (uint256[] memory) {
        return s_ownerParcels[_owner];
    }

    // Function to get all parcels rented by a user
    function getRenterParcels(
        address _renter
    ) external view returns (uint256[] memory) {
        return s_renterParcels[_renter];
    }

    // Function to get all parcels globally
    function getAllParcels() external view returns (uint256[] memory) {
        return s_allParcels;
    }

    function getParcelTraitsHash(
        uint256 _parcelId
    ) external view returns (string memory) {
        return s_adParcels[_parcelId].traitsHash;
    }

    // Function to get the website info hash of a specific ad parcel
    function getWebsiteInfoHash(
        uint256 _parcelId
    ) external view returns (string memory) {
        return s_adParcels[_parcelId].websiteInfoHash;
    }

    // Function to get the content hash of a specific ad parcel
    function getContentHash(
        uint256 _parcelId
    ) external view returns (string memory) {
        return s_adParcels[_parcelId].contentHash;
    }

    // Function to check if a specific ad parcel is active
    function isParcelActive(uint256 _parcelId) external view returns (bool) {
        return s_adParcels[_parcelId].active;
    }

    function getRenterFundsAmount(
        address _renter
    ) external view returns (uint256) {
        return s_renterFunds[_renter];
    }

    function getClickPerAdParcel(
        uint256 _adParcelId
    ) external view returns (uint256) {
        return s_clickPerAdParcel[_adParcelId];
    }

    function getPayableAdParcels() external view returns (uint256[] memory) {
        return s_payableParcels;
    }
}
