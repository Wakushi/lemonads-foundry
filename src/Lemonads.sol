// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract Lemonads is FunctionsClient, Ownable {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    enum ChainlinkRequestType {
        AGGREGATE_CLICKS,
        NOTIFY_RENTER
    }

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

    struct ClicksPerAd {
        uint256 adParcelId;
        uint256 clicks;
    }

    uint256 public constant MIN_CLICK_AMOUNT_COVERED = 10;

    uint256 public constant MIN_INTERVAL_BETWEEN_CRON = 1 days;

    // Mapping to store ad parcels by their ID
    mapping(uint256 adParcelId => AdParcel) private s_adParcels;

    // Mapping to store the aggregated amount of clicks per ad parcel
    mapping(uint256 adParcelId => uint256 clicks) private s_clicksPerAdParcel;

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

    // Chainlink Data Feed
    AggregatorV3Interface private s_priceFeed;

    // Chainlink Functions
    bytes32 s_donID;

    uint32 s_gasLimit = 300000;

    uint64 s_functionsSubId;

    string s_clickAggregatorSource;

    string s_notificationSource;

    bytes32 s_lastRequestId;

    bytes32 s_lastRequestIdFulfilled;

    uint256 s_lastCronExecutionTime;

    uint256 s_requestUUID;

    bytes s_secretReference;

    mapping(bytes32 requestId => ChainlinkRequestType requestType) s_requestTypes;

    // Errors
    error Lemonads__ParcelAlreadyCreatedAtId(uint256 parcelId);
    error Lemonads__ParcelNotFound();
    error Lemonads__UnsufficientFundsLocked();
    error Lemonads__NotZero();
    error Lemonads__TransferFailed();
    error Lemonads__BidLowerThanCurrent();
    error Lemonads__NotParcelOwner();
    error Lemonads__NotEnoughTimePassed();
    error Lemonads__NoPayableParcel();
    error Lemonads__NotificationListEmpty();
    error Lemonads__AddressZero();

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
    event RenterRemovedFromParcel(uint256 adParcelId);
    event AdParcelPaid(
        uint256 indexed adParcelId,
        address indexed renter,
        uint256 indexed renterFunds
    );
    event LowFunds(
        uint256 indexed adParcelId,
        address indexed renter,
        uint256 indexed renterFunds
    );
    event RenterNotified(bytes32 requestId);
    event SentRequestForNotifications();

    modifier onlyAdParcelOwner(uint256 _parcelId) {
        _ensureAdParcelOwnership(_parcelId);
        _;
    }

    constructor(
        address _functionsRouter,
        bytes32 _donId,
        uint64 _functionsSubId,
        string memory _clickAggregatorSource,
        string memory _notificationSource,
        bytes memory _secretReference,
        address _nativeToUsdpriceFeed
    ) FunctionsClient(_functionsRouter) Ownable(msg.sender) {
        s_donID = _donId;
        s_functionsSubId = _functionsSubId;
        s_clickAggregatorSource = _clickAggregatorSource;
        s_notificationSource = _notificationSource;
        s_secretReference = _secretReference;
        s_priceFeed = AggregatorV3Interface(_nativeToUsdpriceFeed);
    }

    // Function to create a new ad parcel
    function createAdParcel(
        uint256 _parcelId,
        uint256 _minBid,
        address _owner,
        string calldata _traitsHash,
        string calldata _websiteInfoHash
    ) external {
        if (_owner == address(0)) {
            revert Lemonads__AddressZero();
        }

        if (s_adParcels[_parcelId].owner != address(0)) {
            revert Lemonads__ParcelAlreadyCreatedAtId(_parcelId);
        }

        s_adParcels[_parcelId] = AdParcel({
            bid: 0,
            minBid: _minBid,
            owner: _owner,
            renter: address(0),
            active: true,
            traitsHash: _traitsHash,
            websiteInfoHash: _websiteInfoHash,
            contentHash: ""
        });

        s_ownerParcels[_owner].push(_parcelId);
        s_allParcels.push(_parcelId);

        emit AdParcelCreated(_parcelId, _owner, _minBid);
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

        if (_newBid < adParcel.bid || _newBid < adParcel.minBid) {
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

    function aggregateClicks() external {
        // DISABLED FOR TESTING PURPOSES

        // if (
        //     block.timestamp <
        //     s_lastCronExecutionTime + MIN_INTERVAL_BETWEEN_CRON
        // ) {
        //     revert Lemonads__NotEnoughTimePassed();
        // }

        string[] memory requestArgs = new string[](1);

        requestArgs[0] = s_lastCronExecutionTime.toString();

        s_lastCronExecutionTime = block.timestamp;

        _generateSendRequest(
            requestArgs,
            s_clickAggregatorSource,
            ChainlinkRequestType.AGGREGATE_CLICKS
        );
    }

    // Triggered manually or using log based automation
    function payParcelOwners() external {
        if (s_payableParcels.length == 0) {
            revert Lemonads__NoPayableParcel();
        }

        uint256[] memory payableParcels = s_payableParcels;

        string[] memory notificationList = new string[](
            payableParcels.length + 1
        );

        for (uint256 i = 0; i < payableParcels.length; i++) {
            // Retrieve the ad parcel ID
            uint256 adParcelId = payableParcels[i];

            // Get clicks amount aggregated (by fulfillRequest()) for that parcel
            uint256 clicksAggregated = s_clicksPerAdParcel[adParcelId];

            AdParcel storage adParcel = s_adParcels[adParcelId];

            // Get the amount due for all clicks * price per click (bid)
            uint256 amountDue = adParcel.bid * clicksAggregated;

            // Get the ETH amount locked by the renter
            uint256 renterFunds = s_renterFunds[adParcel.renter];

            // We calculate the new fund amount expected after payment
            uint256 newExpectedFundAmount;

            // If the renter owes more than he had locked
            if (amountDue > renterFunds) {
                // Everything he has left will be sent as payment
                amountDue = renterFunds;
                s_renterFunds[adParcel.renter] = 0;

                // We remove him from the parcel (+ reputation system ?)
                _freeParcel(adParcelId);

                emit RenterRemovedFromParcel(adParcelId);
            } else {
                // Calculate what's going to remains of renter's funds
                newExpectedFundAmount = renterFunds - amountDue;

                // Deduct the funds
                s_renterFunds[adParcel.renter] -= amountDue;

                // If new fund amount is lower than a certain point, also free the parcel
                if (
                    newExpectedFundAmount <
                    adParcel.bid * MIN_CLICK_AMOUNT_COVERED
                ) {
                    _freeParcel(adParcelId);

                    emit RenterRemovedFromParcel(adParcelId);
                }

                // If the new funds are less than 2 times the expected amount of click covered, send a notification
                if (
                    newExpectedFundAmount <
                    adParcel.bid * MIN_CLICK_AMOUNT_COVERED * 2
                ) {
                    notificationList[i] = Strings.toHexString(
                        uint256(uint160(adParcel.renter)),
                        20
                    );
                }

                emit AdParcelPaid(
                    adParcelId,
                    adParcel.renter,
                    newExpectedFundAmount
                );
            }

            s_clicksPerAdParcel[adParcelId] = 0;

            (bool success, ) = adParcel.owner.call{value: amountDue}("");

            if (!success) {
                emit ParcelPaymentFailed(adParcelId);
            }
        }

        delete s_payableParcels;

        if (notificationList.length > 0) {
            s_requestUUID++;
            notificationList[payableParcels.length] = s_requestUUID.toString();
            notifyRenters(notificationList);
        }
    }

    function notifyRenters(string[] memory _notificationList) internal {
        if (_notificationList.length == 0) {
            revert Lemonads__NotificationListEmpty();
        }

        _generateSendRequest(
            _notificationList,
            s_notificationSource,
            ChainlinkRequestType.NOTIFY_RENTER
        );

        emit SentRequestForNotifications();
    }

    ////////////////////
    // Internal
    ////////////////////

    function _freeParcel(uint256 _adParcelId) internal {
        AdParcel storage adParcel = s_adParcels[_adParcelId];
        adParcel.renter = address(0);
        adParcel.bid = 0;
        adParcel.contentHash = "";
        _removeAdRentedParcel(adParcel.renter, _adParcelId);
    }

    function _generateSendRequest(
        string[] memory _args,
        string memory _source,
        ChainlinkRequestType _requestType
    ) internal returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(_source);
        req.secretsLocation = FunctionsRequest.Location.DONHosted;
        req.encryptedSecretsReference = s_secretReference;
        if (_args.length > 0) {
            req.setArgs(_args);
        }

        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            s_functionsSubId,
            s_gasLimit,
            s_donID
        );

        s_requestTypes[s_lastRequestId] = _requestType;

        emit ChainlinkRequestSent(s_lastRequestId);
        return s_lastRequestId;
    }

    /**
     * @notice Receives the aggregated data computed on the click-aggregator-source.js,
     * as tuple array of ClicksPerAd structs. It runs through the array and increments
     * the click amount for concerned ad parcels. It also adds the parcel that were clicked
     * to an array of payable parcels (to be treated by payParcelOwners())
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        ChainlinkRequestType requestType = s_requestTypes[requestId];

        if (requestType == ChainlinkRequestType.AGGREGATE_CLICKS) {
            ClicksPerAd[] memory clicksPerAds = abi.decode(
                response,
                (ClicksPerAd[])
            );

            for (uint256 i = 0; i < clicksPerAds.length; i++) {
                uint256 adParcelId = clicksPerAds[i].adParcelId;
                s_clicksPerAdParcel[adParcelId] += clicksPerAds[i].clicks;
                s_payableParcels.push(adParcelId);
            }

            s_lastRequestIdFulfilled = requestId;

            emit ClickAggregated(requestId);

            return;
        }

        if (requestType == ChainlinkRequestType.NOTIFY_RENTER) {
            emit RenterNotified(requestId);
        }
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
        return s_clicksPerAdParcel[_adParcelId];
    }

    function getPayableAdParcels() external view returns (uint256[] memory) {
        return s_payableParcels;
    }

    function getLastCronTimestamp() external view returns (uint256) {
        return s_lastCronExecutionTime;
    }

    function updateSecretReference(
        bytes calldata _secretReference
    ) external onlyOwner {
        s_secretReference = _secretReference;
    }

    /**
     * @dev Returns the current price of ETH in USD for dApp frontend usage.
     */
    function getEthPrice() external view returns (uint256) {
        (, int256 price, , , ) = s_priceFeed.latestRoundData();
        return uint256(price);
    }
}
