# Lemonads Smart Contract

Welcome to the **Lemonads** smart contract, a decentralized ad platform built on Ethereum utilizing Chainlink Functions to automate ad management, payments, and notifications. This contract allows publishers to create **ad parcels**, advertisers to bid on those parcels, and handle payments based on clicks generated through ad content.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Contract Components](#contract-components)
  - [Ad Parcel](#ad-parcel)
  - [Clicks and Payments](#clicks-and-payments)
  - [Chainlink Integration](#chainlink-integration)
- [Key Functions](#key-functions)
  - [Parcel Management](#parcel-management)
  - [Bidding and Renting](#bidding-and-renting)
  - [Clicks and Payments](#clicks-and-payments-1)
  - [Chainlink Requests](#chainlink-requests)
- [Events](#events)
- [Error Handling](#error-handling)
- [How to Use](#how-to-use)
- [Deployed](#deployed)

---

## Overview

The **Lemonads** contract is designed for decentralized ad management. It lets publishers create ad parcels and allow advertisers to bid on them. The winning bidder (renter) can upload their ad content, and the platform tracks clicks on the ads using Chainlink’s decentralized oracle network. The payment is based on the number of clicks aggregated, and notifications are sent to renters to top up their budgets if needed.

---

## Features

- **Ad Parcel Creation**: Publishers can create ad parcels with a minimum bid and metadata stored on IPFS.
- **Decentralized Bidding**: Advertisers can place bids and rent ad parcels, submitting their ad content.
- **Click Aggregation**: Chainlink Functions are used to aggregate clicks on ad parcels.
- **Automated Payments**: Payments to publishers are automated based on click count and the ad bid.
- **Notifications**: Chainlink Functions notify renters when their budget runs low.

---

## Contract Components

### Ad Parcel

An **AdParcel** represents an ad slot that publishers can rent to advertisers. Each parcel contains:

- `bid`: Current highest bid for the parcel.
- `minBid`: Minimum acceptable bid for the parcel.
- `owner`: Publisher who owns the ad parcel.
- `renter`: Current renter (advertiser) of the parcel.
- `traitsHash`: IPFS hash for parcel metadata (such as dimensions, fonts, etc.).
- `contentHash`: IPFS hash for the ad content uploaded by the renter.
- `websiteInfoHash`: IPFS hash for website-related data.
- `active`: Whether the parcel is currently active.

### Clicks and Payments

The contract tracks clicks on ad parcels through Chainlink Functions and automates payments to publishers based on the number of clicks an ad generates. The payment is derived from the `bid` value of the ad parcel and the number of clicks aggregated.

### Chainlink Integration

This contract utilizes **Chainlink Functions** for several important operations:

- **Click Aggregation**: Aggregating clicks from decentralized oracles to determine the total clicks on each ad parcel.
- **Notifications**: Sending alerts to renters when their budgets run low.

---

## Key Functions

### Parcel Management

1. **createAdParcel**

   - Allows a publisher to create a new ad parcel with a minimum bid, metadata, and website information.
   - Emits the `AdParcelCreated` event.

2. **updateTraits**

   - Allows the owner of a parcel to update its traits (visual settings, dimensions, etc.).
   - Emits the `TraitsUpdated` event.

3. **updateWebsite**

   - Updates the website information linked to the ad parcel.
   - Emits the `WebsiteInfoUpdated` event.

4. **closeParcel**
   - Closes the ad parcel and resets its renter, bid, and other key parameters.

### Bidding and Renting

1. **rentAdParcel**

   - Allows an advertiser to place a bid and rent an ad parcel by submitting their content and the bid.
   - The bid must be higher than the current bid and must meet the minimum bid criteria.
   - Emits the `AdParcelRented` event.

2. **releaseParcel**

   - Allows a renter to release their rented ad parcel.
   - Emits the `AdParcelReleased` event.

3. **addBudget**

   - Lets renters add a budget for paying for clicks on their rented parcels.
   - Emits the `BudgetAdded` event.

4. **withdrawBudget**
   - Renters can withdraw any unused budget for a parcel.
   - Emits the `BudgetWithdrawn` event.

### Clicks and Payments

1. **aggregateClicks**

   - Aggregates clicks for all parcels using Chainlink Functions.
   - Emits the `ClickAggregated` event.

2. **payParcelOwners**
   - Automatically pays out publishers based on the number of clicks accumulated for their parcels.
   - Emits the `AdParcelPaid` and `RenterRemovedFromParcel` events in case of payment failure or renter removal.

### Chainlink Requests

1. **\_generateSendRequest**

   - Internal function to create and send a Chainlink request based on the provided source code and arguments.
   - Sends the request and emits the `ChainlinkRequestSent` event.

2. **fulfillRequest**
   - Handles the fulfillment of Chainlink requests.
   - Processes clicks or notification results based on the request type.
   - Emits the `ClickAggregated` or `RenterNotified` event.

---

## Events

- **AdParcelCreated**: Emitted when a new ad parcel is created.
- **AdParcelRented**: Emitted when an ad parcel is rented.
- **AdParcelReleased**: Emitted when an ad parcel is released by the renter.
- **TraitsUpdated**: Emitted when the traits of an ad parcel are updated.
- **WebsiteInfoUpdated**: Emitted when the website information is updated.
- **AdParcelPaid**: Emitted when a publisher is paid for clicks on their parcel.
- **RenterRemovedFromParcel**: Emitted when a renter is removed due to insufficient funds.
- **ClickAggregated**: Emitted when clicks are aggregated through Chainlink.
- **BudgetAdded**: Emitted when a renter adds a budget to their parcel.
- **BudgetWithdrawn**: Emitted when a renter withdraws funds from their budget.
- **ChainlinkRequestSent**: Emitted when a Chainlink request is sent.
- **RenterNotified**: Emitted when renters are notified of low budget.

---

## Error Handling

The contract includes a set of custom errors to handle specific edge cases:

- **ParcelAlreadyCreatedAtId**: Thrown when trying to create a parcel that already exists at a given ID.
- **ParcelNotFound**: Thrown when trying to access a parcel that doesn't exist.
- **UnsufficientBudgetLocked**: Thrown when the renter's budget is insufficient to cover expected clicks.
- **NotParcelOwner**: Thrown when someone other than the parcel owner tries to perform an owner-only action.
- **TransferFailed**: Thrown when ETH transfers fail during payment.
- **BidLowerThanCurrent**: Thrown when the bid is lower than the current bid or the minimum bid.
- **NoPayableParcel**: Thrown when there are no parcels expecting payment.
- **NotificationListEmpty**: Thrown when attempting to notify renters but the notification list is empty.

---

## How to Use

1. **Create an Ad Parcel**: Publishers can create ad parcels by calling `createAdParcel` with a minimum bid and IPFS metadata hashes.
2. **Rent an Ad Parcel**: Advertisers can rent an ad parcel by placing a bid that meets or exceeds the current bid and providing their ad content.
3. **Add Budget**: Renters can add a budget to their ad parcel to cover clicks.
4. **Aggregate Clicks**: The system automatically aggregates clicks using Chainlink Functions.
5. **Payments**: After clicks are aggregated, publishers are paid based on the number of clicks and the ad's bid.

---

## Deploy

```bash
make deployLemonads ARGS="--network base"
```

This contract is designed to make decentralized advertising more accessible and efficient by automating key processes like bidding, payments, and notifications, leveraging Chainlink’s decentralized infrastructure for transparency and security.

# Deployed

## CHAINLINK CRONS

### Aggregate clicks

https://automation.chain.link/base-sepolia/21209483081823356663322472164827408755917060974019223499028362850358406529008

### Pay ad parcel owners

https://automation.chain.link/base-sepolia/81585211095348955229576301214346664747482029634717746752085909777532966859365
