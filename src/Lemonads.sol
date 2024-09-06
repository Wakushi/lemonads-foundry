// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract Lemonads is FunctionsClient, Ownable {
    ///////////////////
    // Type declarations
    ///////////////////

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
        string contentHash; // IPFS hash for ad campaign content
        string websiteInfoHash; // IPFS hash for host website information
        bool active; // Is this parcel still active
    }

    struct ClicksPerAd {
        uint256 adParcelId;
        uint256 clicks;
    }

    ///////////////////
    // State variables
    ///////////////////

    uint256 public constant MIN_CLICK_AMOUNT_COVERED = 10;

    uint256 public constant MIN_INTERVAL_BETWEEN_CRON = 1 days;

    /**
     * @dev Mapping to store ad parcels by their ID.
     *      Each parcel is identified by a unique `adParcelId` and stores information such as the current bid, minimum bid, owner, renter, and content/traits.
     */
    mapping(uint256 adParcelId => AdParcel) private s_adParcels;

    /**
     * @dev Mapping to store the aggregated amount of clicks per ad parcel.
     *      Maps the `adParcelId` to the total number of clicks received by the parcel.
     */
    mapping(uint256 adParcelId => uint256 clicks) private s_clicksPerAdParcel;

    /**
     * @dev Mapping from owner (publisher) to an array of owned ad parcel IDs.
     *      Stores which ad parcels are owned by a given publisher.
     */
    mapping(address publisher => uint256[] adParcelIds) private s_ownerParcels;

    /**
     * @dev Mapping from renter to an array of rented ad parcel IDs.
     *      Keeps track of which ad parcels are rented by each renter.
     */
    mapping(address renter => uint256[] adParcelIds) private s_renterParcels;

    /**
     * @dev Mapping to store the locked budget for each renter, per ad parcel.
     *      Maps a renter's address and `adParcelId` to the budget locked for that specific ad parcel.
     */
    mapping(address renter => mapping(uint256 adParcelId => uint256 budget))
        private s_renterBudgetPerParcel;

    /**
     * @dev Mapping to store the total earnings per ad parcel.
     *      Maps the `adParcelId` to the total number of earnings paid to this parcel.
     */
    mapping(uint256 adParcelId => uint256 amount) private s_earningsPerAdParcel;

    /**
     * @dev Global array to store all parcel IDs.
     *      A list of all ad parcels that exist in the system.
     */
    uint256[] private s_allParcels;

    /**
     * @dev Array of ad parcel IDs that are expecting payments.
     *      Contains ad parcels that require payment settlements (e.g., for clicks or impressions).
     */
    uint256[] private s_payableParcels;

    // Chainlink Data Feed to fetch pricing information
    AggregatorV3Interface private s_priceFeed;

    // Chainlink Functions DON (Decentralized Oracle Network) ID
    bytes32 s_donID;

    // Gas limit for Chainlink Functions calls
    uint32 s_gasLimit = 300000;

    // Chainlink Functions subscription ID
    uint64 s_functionsSubId;

    // Source code for click aggregation in Chainlink Functions
    string s_clickAggregatorSource;

    // Source code for notification triggers in Chainlink Functions
    string s_notificationSource;

    // The last Chainlink request ID sent
    bytes32 s_lastRequestId;

    // The last Chainlink request ID that was fulfilled
    bytes32 s_lastRequestIdFulfilled;

    // The timestamp of the last cron execution
    uint256 s_lastCronExecutionTime;

    // UUID for requests
    uint256 s_requestUUID;

    // Reference to secret data for Chainlink Functions
    bytes s_secretReference;

    /**
     * @dev Mapping to associate a Chainlink request ID to the type of request made (e.g., AGGREGATE_CLICKS, NOTIFY_RENTER).
     *      Used to differentiate between different types of Chainlink requests.
     */
    mapping(bytes32 requestId => ChainlinkRequestType requestType) s_requestTypes;

    ///////////////////
    // Events
    ///////////////////

    event RenterNotified(bytes32 requestId);
    event SentRequestForNotifications();
    event BudgetAdded(address indexed renter, uint256 amount);
    event BudgetWithdrawn(address indexed renter, uint256 amount);
    event ChainlinkRequestSent(bytes32 requestId);
    event ClickAggregated(bytes32 requestId);
    event ParcelPaymentFailed(uint256 adParcelId);
    event RenterRemovedFromParcel(uint256 adParcelId);
    event MinBidUpdated(uint256 indexed parcelId, uint256 newMinBid);
    event TraitsUpdated(uint256 indexed parcelId, string traitsHash);
    event AdContentUpdated(uint256 indexed parcelId, string contentHash);
    event WebsiteInfoUpdated(uint256 indexed parcelId, string websiteInfoHash);
    event AdParcelRented(
        uint256 indexed parcelId,
        address indexed renter,
        uint256 bid
    );
    event AdParcelReleased(
        uint256 indexed parcelId,
        address indexed prevRenter
    );
    event AdParcelCreated(
        uint256 indexed parcelId,
        address indexed owner,
        uint256 minBid
    );
    event AdParcelPaid(
        uint256 indexed adParcelId,
        address indexed renter,
        uint256 indexed renterBudget
    );
    event LowBudget(
        uint256 indexed adParcelId,
        address indexed renter,
        uint256 indexed renterBudget
    );

    //////////////////
    // Errors
    ///////////////////

    error Lemonads__ParcelAlreadyCreatedAtId(uint256 parcelId);
    error Lemonads__ParcelNotFound();
    error Lemonads__UnsufficientBudgetLocked();
    error Lemonads__NotZero();
    error Lemonads__TransferFailed();
    error Lemonads__BidLowerThanCurrent();
    error Lemonads__NotParcelOwner();
    error Lemonads__NotEnoughTimePassed();
    error Lemonads__NoPayableParcel();
    error Lemonads__NotificationListEmpty();
    error Lemonads__AddressZero();
    error Lemonads__NotParcelRenter();

    //////////////////
    // Functions
    //////////////////

    modifier onlyAdParcelOwner(uint256 _parcelId) {
        _ensureAdParcelOwnership(_parcelId);
        _;
    }

    modifier onlyAdParcelRenter(uint256 _parcelId) {
        _ensureAdParcelRenter(_parcelId);
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

    ////////////////////
    // External / Public
    ////////////////////

    /**
     * @notice Creates a new ad parcel with the specified parameters.
     * @dev The ad parcel is identified by the `_parcelId`. The function sets the minimum bid, owner, and metadata hashes for the parcel.
     *      The parcel is then stored in the mapping and the owner is assigned the parcel.
     * @param _parcelId The unique ID of the ad parcel being created.
     * @param _minBid The minimum bid required to rent the ad parcel.
     * @param _owner The address of the owner (publisher) of the ad parcel.
     * @param _traitsHash The IPFS hash storing traits metadata of the parcel (e.g., size, fonts, layout).
     * @param _websiteInfoHash The IPFS hash storing website information metadata (e.g., domain, traffic).
     * @dev Emits `AdParcelCreated` event upon successful creation of the ad parcel.
     * @dev Reverts with `Lemonads__AddressZero` if the `_owner` address is zero.
     * @dev Reverts with `Lemonads__ParcelAlreadyCreatedAtId` if a parcel with the same `_parcelId` already exists.
     */
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

    /**
     * @notice Places a bid to rent an ad parcel and updates its content.
     * @dev This function allows a user to place a bid higher than the current bid or minimum bid to rent the ad parcel.
     *      It locks the renter's budget based on the bid and sets the content for the parcel.
     * @param _parcelId The ID of the ad parcel being rented.
     * @param _newBid The new bid amount for renting the ad parcel.
     * @param _contentHash The IPFS hash pointing to the content that will be displayed in the ad parcel.
     * @dev The function will revert with `Lemonads__ParcelNotFound` if the ad parcel does not exist.
     * @dev Reverts with `Lemonads__BidLowerThanCurrent` if the `_newBid` is lower than the current bid or the minimum bid.
     * @dev Reverts with `Lemonads__UnsufficientBudgetLocked` if the renter has not locked sufficient budget to cover at least `MIN_CLICK_AMOUNT_COVERED` clicks.
     * @dev Emits `AdParcelRented` event when the ad parcel is successfully rented.
     * @dev If the parcel was already rented, the previous renter is removed via `_removeAdRentedParcel`.
     */
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

        s_renterBudgetPerParcel[msg.sender][_parcelId] += msg.value;

        if (
            s_renterBudgetPerParcel[msg.sender][_parcelId] <
            (adParcel.bid * MIN_CLICK_AMOUNT_COVERED)
        ) {
            revert Lemonads__UnsufficientBudgetLocked();
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

    /**
     * @notice Releases the current renter from the specified ad parcel, making it available for rent again.
     * @dev This function can only be called by the current renter of the ad parcel.
     * @param _parcelId The ID of the ad parcel to be released.
     * @dev Emits an `AdParcelReleased` event upon successful release.
     */
    function releaseParcel(
        uint256 _parcelId
    ) external onlyAdParcelRenter(_parcelId) {
        _freeParcel(_parcelId);
        emit AdParcelReleased(_parcelId, msg.sender);
    }

    /**
     * @notice Updates the content displayed on the specified ad parcel.
     * @dev This function can only be called by the current renter of the ad parcel.
     * @param _parcelId The ID of the ad parcel to be updated.
     * @param _contentHash The IPFS hash pointing to the new content to be displayed in the ad parcel.
     * @dev Emits an `AdContentUpdated` event upon successful update.
     */
    function updateAdContent(
        uint256 _parcelId,
        string calldata _contentHash
    ) external onlyAdParcelRenter(_parcelId) {
        s_adParcels[_parcelId].contentHash = _contentHash;

        emit AdContentUpdated(_parcelId, _contentHash);
    }

    /**
     * @notice Updates the traits of the specified ad parcel.
     * @dev This function can only be called by the owner of the ad parcel.
     * @param _parcelId The ID of the ad parcel whose traits are to be updated.
     * @param _traitsHash The IPFS hash pointing to the updated traits metadata of the parcel (e.g., size, fonts).
     * @dev Emits a `TraitsUpdated` event upon successful update.
     */
    function updateTraits(
        uint256 _parcelId,
        string calldata _traitsHash
    ) external onlyAdParcelOwner(_parcelId) {
        s_adParcels[_parcelId].traitsHash = _traitsHash;

        emit TraitsUpdated(_parcelId, _traitsHash);
    }

    /**
     * @notice Updates the website information associated with the specified ad parcel.
     * @dev This function can only be called by the owner of the ad parcel.
     * @param _parcelId The ID of the ad parcel whose website information is to be updated.
     * @param _websiteInfoHash The IPFS hash pointing to the updated website information metadata.
     * @dev Emits a `WebsiteInfoUpdated` event upon successful update.
     */
    function updateWebsite(
        uint256 _parcelId,
        string calldata _websiteInfoHash
    ) external onlyAdParcelOwner(_parcelId) {
        s_adParcels[_parcelId].websiteInfoHash = _websiteInfoHash;

        emit WebsiteInfoUpdated(_parcelId, _websiteInfoHash);
    }

    /**
     * @notice Updates the minimum bid required for the specified ad parcel.
     * @dev This function can only be called by the owner of the ad parcel.
     * @param _parcelId The ID of the ad parcel whose minimum bid is to be updated.
     * @param _minBid The new minimum bid required to rent the ad parcel.
     * @dev Emits a `MinBidUpdated` event upon successful update.
     */
    function updateMinBid(
        uint256 _parcelId,
        uint256 _minBid
    ) external onlyAdParcelOwner(_parcelId) {
        s_adParcels[_parcelId].minBid = _minBid;

        emit MinBidUpdated(_parcelId, _minBid);
    }

    /**
     * @notice Adds budget to the renter's account for the specified ad parcel.
     * @dev The renter can increase the budget allocated for covering the ad parcel's costs.
     * @param _parcelId The ID of the ad parcel for which the budget is being added.
     * @dev Reverts with `Lemonads__NotZero` if the `msg.value` is zero.
     * @dev Emits a `BudgetAdded` event upon successful budget addition.
     */
    function addBudget(uint256 _parcelId) external payable {
        if (msg.value == 0) {
            revert Lemonads__NotZero();
        }

        s_renterBudgetPerParcel[msg.sender][_parcelId] += msg.value;

        emit BudgetAdded(msg.sender, msg.value);
    }

    /**
     * @notice Withdraws budget from the renter's account for the specified ad parcel.
     * @dev Allows the renter to withdraw excess budget from their account.
     * @param _parcelId The ID of the ad parcel from which the budget is being withdrawn.
     * @param _amount The amount of budget to withdraw.
     * @dev Reverts with `Lemonads__UnsufficientBudgetLocked` if the requested withdrawal amount exceeds the available budget.
     * @dev Reverts with `Lemonads__TransferFailed` if the transfer of funds to the renter's address fails.
     * @dev Emits a `BudgetWithdrawn` event upon successful withdrawal.
     */
    function withdrawBudget(uint256 _parcelId, uint256 _amount) external {
        if (_amount > s_renterBudgetPerParcel[msg.sender][_parcelId]) {
            revert Lemonads__UnsufficientBudgetLocked();
        }

        s_renterBudgetPerParcel[msg.sender][_parcelId] -= _amount;

        (bool success, ) = msg.sender.call{value: _amount}("");
        if (!success) {
            revert Lemonads__TransferFailed();
        }

        emit BudgetWithdrawn(msg.sender, _amount);
    }

    /**
     * @notice Closes the specified ad parcel, making it inactive and resetting its bid and renter.
     * @dev This function can only be called by the owner of the ad parcel.
     * @param _parcelId The ID of the ad parcel to be closed.
     * @dev The ad parcel is marked inactive, its bid is reset, and the renter is removed.
     */
    function closeParcel(
        uint256 _parcelId
    ) external onlyAdParcelOwner(_parcelId) {
        AdParcel storage adParcel = s_adParcels[_parcelId];
        adParcel.active = false;
        adParcel.bid = 0;
        adParcel.renter = address(0);
        adParcel.websiteInfoHash = "";
    }

    /**
     * @notice Aggregates clicks for ad parcels since the last execution time (see functions/sources/click-aggregator-source.js)
     * @dev This function is used to trigger a Chainlink request that aggregates click data from external sources.
     * The function uses the last cron execution time as the starting point for aggregation.
     * @dev It updates the last cron execution time with the current block timestamp and generates a Chainlink request.
     * @dev Emits a `ChainlinkRequestSent` event upon generating the request.
     */
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

    /**
     * @notice Pays the parcel owners based on the number of clicks accumulated for each ad parcel.
     * @dev The function iterates through payable parcels, calculates the amount due for each parcel based on the
     * number of clicks and the bid per click, and pays the parcel owner accordingly.
     * @dev If the renter's locked budget is insufficient, they are removed from the parcel.
     * @dev Sends a notification to renters when their budget falls below a certain threshold.
     * @dev Emits events for successful payments (`AdParcelPaid`), failed payments (`ParcelPaymentFailed`),
     * and removal of renters from parcels (`RenterRemovedFromParcel`).
     * @dev Reverts with `Lemonads__NoPayableParcel` if there are no parcels expecting payment.
     */
    function payParcelOwners() external {
        if (s_payableParcels.length == 0) {
            revert Lemonads__NoPayableParcel();
        }

        uint256[] memory payableParcels = s_payableParcels;

        string[] memory notificationList = new string[](
            (payableParcels.length * 2) + 1
        );

        for (uint256 i = 0; i < payableParcels.length; i++) {
            // Retrieve the ad parcel ID
            uint256 adParcelId = payableParcels[i];

            // Get clicks amount aggregated (by fulfillRequest()) for that parcel
            uint256 clicksAggregated = s_clicksPerAdParcel[adParcelId];

            AdParcel storage adParcel = s_adParcels[adParcelId];

            // Get the amount due for all clicks * price per click (bid)
            uint256 amountDue = adParcel.bid * clicksAggregated;

            address renter = adParcel.renter;

            // Get the ETH amount locked by the renter
            uint256 renterBudget = s_renterBudgetPerParcel[renter][adParcelId];

            // We calculate the new fund amount expected after payment
            uint256 newExpectedFundAmount;

            // If the renter owes more than he had locked
            if (amountDue > renterBudget) {
                // Everything he has left will be sent as payment
                amountDue = renterBudget;
                s_renterBudgetPerParcel[renter][adParcelId] = 0;

                // We remove him from the parcel (+ reputation system ?)
                _freeParcel(adParcelId);

                emit RenterRemovedFromParcel(adParcelId);
            } else {
                // Calculate what's going to remains of renter's budget
                newExpectedFundAmount = renterBudget - amountDue;

                // Deduct the budget
                s_renterBudgetPerParcel[renter][adParcelId] -= amountDue;

                // If new fund amount is lower than a certain point, also free the parcel
                if (
                    newExpectedFundAmount <
                    adParcel.bid * MIN_CLICK_AMOUNT_COVERED
                ) {
                    _freeParcel(adParcelId);

                    emit RenterRemovedFromParcel(adParcelId);
                }

                // If the new budget are less than 2 times the expected amount of click covered, send a notification
                if (
                    newExpectedFundAmount <
                    adParcel.bid * MIN_CLICK_AMOUNT_COVERED * 2
                ) {
                    notificationList[i * 2] = Strings.toHexString(
                        uint256(uint160(renter)),
                        20
                    ); // Renter address
                    notificationList[i * 2 + 1] = adParcelId.toString(); // Parcel ID
                }

                emit AdParcelPaid(adParcelId, renter, newExpectedFundAmount);
            }

            s_clicksPerAdParcel[adParcelId] = 0;
            s_earningsPerAdParcel[adParcelId] += amountDue;

            (bool success, ) = adParcel.owner.call{value: amountDue}("");

            if (!success) {
                emit ParcelPaymentFailed(adParcelId);
            }
        }

        delete s_payableParcels;

        if (notificationList.length > 0) {
            s_requestUUID++;
            notificationList[notificationList.length - 1] = s_requestUUID
                .toString();
            notifyRenters(notificationList);
        }
    }

    /**
     * @notice Sends notifications to renters based on the provided notification list (see functions/source/notification-source.js)
     * @dev Generates a Chainlink request to notify renters that their budgets are running low.
     * @param _notificationList The list of renter addresses that need to be notified, along with a unique request UUID at the end of the array.
     * @dev Reverts with `Lemonads__NotificationListEmpty` if the notification list is empty.
     * @dev Emits a `SentRequestForNotifications` event upon successful request generation.
     */
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

    /**
     * @notice Frees an ad parcel by resetting its renter, bid, and content hash.
     * @dev This function is called when a renter is removed from an ad parcel due to insufficient budget
     * or when the parcel is released manually.
     * @param _adParcelId The ID of the ad parcel to be freed.
     * @dev Resets the renter address to zero, clears the current bid, and removes the content hash.
     * @dev Also removes the parcel from the renter's rented parcel list.
     */
    function _freeParcel(uint256 _adParcelId) internal {
        AdParcel storage adParcel = s_adParcels[_adParcelId];
        _removeAdRentedParcel(adParcel.renter, _adParcelId);
        adParcel.renter = address(0);
        adParcel.bid = 0;
        adParcel.contentHash = "";
    }

    /**
     * @notice Generates and sends a Chainlink request based on the provided source and arguments.
     * @dev This function creates a Chainlink request using the FunctionsRequest library and sends it
     * with the specified gas limit and subscription ID.
     * @param _args The arguments to be passed to the Chainlink request (e.g., timestamps or data).
     * @param _source The JavaScript source code to be executed by the Chainlink node.
     * @param _requestType The type of request, either AGGREGATE_CLICKS or NOTIFY_RENTER.
     * @return requestId The ID of the Chainlink request that was sent.
     * @dev Emits a `ChainlinkRequestSent` event upon successful request generation.
     */
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
     * @notice Fulfills a Chainlink request by processing the response or handling errors.
     * @dev This function is called when a Chainlink request is fulfilled, depending on the request type.
     * If the request was an AGGREGATE_CLICKS request, it decodes the click data and updates the click count
     * for each ad parcel.
     * @param requestId The ID of the fulfilled Chainlink request.
     * @param response The response data returned by the Chainlink node.
     * @param err The error message, if any, returned by the Chainlink node.
     * @dev Emits a `ClickAggregated` event if clicks were aggregated, or a `RenterNotified` event for notifications.
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

    /**
     * @notice Removes an ad parcel from the list of parcels rented by a specific renter.
     * @dev This function is used when a renter is removed from a parcel, either due to insufficient budget
     * or manual release.
     * @param _renter The address of the renter to remove the parcel from.
     * @param _parcelId The ID of the ad parcel to remove from the renter's list.
     */
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

    function _ensureAdParcelRenter(uint256 _parcelId) internal view {
        if (s_adParcels[_parcelId].renter != msg.sender) {
            revert Lemonads__NotParcelRenter();
        }
    }

    ////////////////////
    // External / Public View
    ////////////////////

    function getAdParcelById(
        uint256 _parcelId
    ) external view returns (AdParcel memory) {
        return s_adParcels[_parcelId];
    }

    function getOwnerParcels(
        address _owner
    ) external view returns (uint256[] memory) {
        return s_ownerParcels[_owner];
    }

    function getRenterParcels(
        address _renter
    ) external view returns (uint256[] memory) {
        return s_renterParcels[_renter];
    }

    function getAllParcels() external view returns (uint256[] memory) {
        return s_allParcels;
    }

    function getParcelTraitsHash(
        uint256 _parcelId
    ) external view returns (string memory) {
        return s_adParcels[_parcelId].traitsHash;
    }

    function getWebsiteInfoHash(
        uint256 _parcelId
    ) external view returns (string memory) {
        return s_adParcels[_parcelId].websiteInfoHash;
    }

    function getContentHash(
        uint256 _parcelId
    ) external view returns (string memory) {
        return s_adParcels[_parcelId].contentHash;
    }

    function isParcelActive(uint256 _parcelId) external view returns (bool) {
        return s_adParcels[_parcelId].active;
    }

    function getRenterBudgetAmountByParcel(
        uint256 _parcelId,
        address _renter
    ) external view returns (uint256) {
        return s_renterBudgetPerParcel[_renter][_parcelId];
    }

    function getClickPerAdParcel(
        uint256 _parcelId
    ) external view returns (uint256) {
        return s_clicksPerAdParcel[_parcelId];
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

    function getEthPrice() external view returns (uint256) {
        (, int256 price, , , ) = s_priceFeed.latestRoundData();
        return uint256(price);
    }

    function getEarningsByAdParcel(
        uint256 _parcelId
    ) external view returns (uint256) {
        return s_earningsPerAdParcel[_parcelId];
    }
}
