pragma solidity 0.5.17;

import "./ERC721Patronage_v1.sol";
import "./MintManager_v2.sol";

// import "@nomiclabs/buidler/console.sol";

contract WildcardSteward_v3 is Initializable {
    /*
    This smart contract collects patronage from current owner through a Harberger tax model and 
    takes stewardship of the asset token if the patron can't pay anymore.

    Harberger Tax (COST): 
    - Asset is always on sale.
    - You have to have a price set.
    - Tax (Patronage) is paid to maintain ownership.
    - Steward maints control over ERC721.
    */
    using SafeMath for uint256;
    mapping(uint256 => uint256) public price; //in wei
    ERC721Patronage_v1 public assetToken; // ERC721 NFT.

    mapping(uint256 => uint256) deprecated_totalCollected; // THIS VALUE IS DEPRECATED
    mapping(uint256 => uint256) deprecated_currentCollected; // THIS VALUE IS DEPRECATED
    mapping(uint256 => uint256) deprecated_timeLastCollected; // THIS VALUE IS DEPRECATED.
    mapping(address => uint256) public timeLastCollectedPatron;
    mapping(address => uint256) public deposit;
    mapping(address => uint256) public totalPatronOwnedTokenCost;

    mapping(uint256 => address) public benefactors; // non-profit benefactor
    mapping(address => uint256) public benefactorFunds;

    mapping(uint256 => address) deprecated_currentPatron; // Deprecate This is different to the current token owner.
    mapping(uint256 => mapping(address => bool)) deprecated_patrons; // Deprecate
    mapping(uint256 => mapping(address => uint256)) deprecated_timeHeld; // Deprecate

    mapping(uint256 => uint256) deprecated_timeAcquired; // deprecate

    // 1200% patronage
    mapping(uint256 => uint256) public patronageNumerator;
    uint256 public patronageDenominator;

    enum StewardState {Foreclosed, Owned}
    mapping(uint256 => StewardState) public state;

    address public admin;

    //////////////// NEW variables in v2///////////////////
    mapping(uint256 => uint256) deprecated_tokenGenerationRate; // we can reuse the patronage denominator

    MintManager_v2 public mintManager;
    //////////////// NEW variables in v3 ///////////////////
    uint256 public auctionStartPrice;
    uint256 public auctionEndPrice;
    uint256 public auctionLength;

    mapping(uint256 => address) public artistAddresses; //mapping from tokenID to the artists address
    mapping(uint256 => uint256) public wildcardsPercentages; // mapping from tokenID to the percentage sale cut of wildcards for each token
    mapping(uint256 => uint256) public artistPercentages; // tokenId to artist percetages. To make it configurable. 10 000 = 100%
    mapping(uint256 => uint256) public tokenAuctionBeginTimestamp;

    mapping(address => uint256) public totalPatronTokenGenerationRate; // The total token generation rate for all the tokens of the given address.
    mapping(address => uint256) public totalBenefactorTokenNumerator;
    mapping(address => uint256) public timeLastCollectedBenefactor; // make my name consistent please
    mapping(address => uint256) public benefactorCredit;
    address public withdrawCheckerAdmin;

    /*
    31536000 seconds = 365 days

    divisor = 365 days * 1000000000000
            = 31536000000000000000
    */

    // 11574074074074 = 10^18 / 86400 This is just less (rounded down) than one token a day.
    //       - this can be done since all tokens have the exact same tokenGenerationRate - and hardcoding saves gas.
    uint256 public constant globalTokenGenerationRate = 11574074074074;
    uint256 public constant yearTimePatronagDenominator = 31536000000000000000;

    event Buy(uint256 indexed tokenId, address indexed owner, uint256 price);
    event PriceChange(uint256 indexed tokenId, uint256 newPrice);
    event Foreclosure(address indexed prevOwner, uint256 foreclosureTime);
    event RemainingDepositUpdate(
        address indexed tokenPatron,
        uint256 remainingDeposit
    );

    event AddTokenV3(
        uint256 indexed tokenId,
        uint256 patronageNumerator,
        uint256 unixTimestampOfTokenAuctionStart
    );

    // QUESTION: in future versions, should these two events (CollectPatronage and CollectLoyalty) be combined into one? - they only ever happen at the same time.
    // NOTE: this event is deprecated - it is only here for the upgrade function.
    event CollectPatronage(
        uint256 indexed tokenId,
        address indexed patron,
        uint256 remainingDeposit,
        uint256 amountReceived
    );
    event CollectLoyalty(address indexed patron, uint256 amountRecieved);

    event ArtistCommission(
        uint256 indexed tokenId,
        address artist,
        uint256 artistCommission
    );
    event WithdrawBenefactorFundsWithSafetyDelay(
        address indexed benefactor,
        uint256 withdrawAmount
    );
    event WithdrawBenefactorFunds(
        address indexed benefactor,
        uint256 withdrawAmount
    );
    event UpgradeToV3();
    event ChangeAuctionParameters();

    modifier onlyPatron(uint256 tokenId) {
        require(msg.sender == assetToken.ownerOf(tokenId), "Not patron");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyReceivingBenefactorOrAdmin(uint256 tokenId) {
        require(
            msg.sender == benefactors[tokenId] || msg.sender == admin,
            "Not benefactor or admin"
        );
        _;
    }

    modifier collectPatronageAndSettleBenefactor(uint256 tokenId) {
        _collectPatronageAndSettleBenefactor(tokenId);
        _;
    }

    modifier collectPatronagePatron(address tokenPatron) {
        _collectPatronagePatron(tokenPatron);
        _;
    }

    modifier youCurrentlyAreNotInDefault(address tokenPatron) {
        require(
            !(deposit[tokenPatron] == 0 &&
                totalPatronOwnedTokenCost[tokenPatron] > 0),
            "no deposit existing tokens"
        );
        _;
    }

    modifier updateBenefactorBalance(address benefactor) {
        _updateBenefactorBalance(benefactor);
        _;
    }

    modifier priceGreaterThanZero(uint256 _newPrice) {
        require(_newPrice > 0, "Price is zero");
        _;
    }
    modifier notNullAddress(address checkAddress) {
        require(checkAddress != address(0), "null address");
        _;
    }
    modifier notSameAddress(address firstAddress, address secondAddress) {
        require(firstAddress != secondAddress, "cannot be same address");
        _;
    }
    modifier validWildcardsPercentage(
        uint256 wildcardsPercentage,
        uint256 tokenID
    ) {
        require(
            wildcardsPercentage >= 50000 &&
                wildcardsPercentage <= (1000000 - artistPercentages[tokenID]), // not sub safemath. Is this okay?
            "wildcards commision not between 5% and 100%"
        );
        _;
    }

    function initialize(
        address _assetToken,
        address _admin,
        address _mintManager,
        address _withdrawCheckerAdmin,
        uint256 _auctionStartPrice,
        uint256 _auctionEndPrice,
        uint256 _auctionLength
    ) public initializer {
        assetToken = ERC721Patronage_v1(_assetToken);
        admin = _admin;
        withdrawCheckerAdmin = _withdrawCheckerAdmin;
        mintManager = MintManager_v2(_mintManager);
        _changeAuctionParameters(
            _auctionStartPrice,
            _auctionEndPrice,
            _auctionLength
        );
    }

    function uintToStr(uint256 _i)
        internal
        pure
        returns (string memory _uintAsString)
    {
        if (_i == 0) {
            return "0";
        }

        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }

        bytes memory bstr = new bytes(len);
        while (_i != 0) {
            bstr[--len] = bytes1(uint8(48 + (_i % 10)));
            _i /= 10;
        }
        return string(bstr);
    }

    function listNewTokens(
        uint256[] memory tokens,
        address payable[] memory _benefactors,
        uint256[] memory _patronageNumerator,
        address[] memory _artists,
        uint256[] memory _artistCommission,
        uint256[] memory _releaseDate
    ) public onlyAdmin {
        assert(tokens.length == _benefactors.length);
        assert(tokens.length == _patronageNumerator.length);
        assert(tokens.length == _releaseDate.length);
        assert(_artists.length == _artistCommission.length);

        for (uint8 i = 0; i < tokens.length; ++i) {
            address benefactor = _benefactors[i];
            require(_benefactors[i] != address(0), "null address");
            string memory idString = uintToStr(tokens[i]);
            string memory tokenUriBase = "https://wildcards.xyz/token/";
            string memory tokenUri = string(
                abi.encodePacked(tokenUriBase, idString)
            );
            assetToken.mintWithTokenURI(address(this), tokens[i], tokenUri);
            benefactors[tokens[i]] = _benefactors[i];
            state[tokens[i]] = StewardState.Foreclosed;
            patronageNumerator[tokens[i]] = _patronageNumerator[i];
            // tokenGenerationRate[tokens[i]] = _tokenGenerationRate[i];

            if (_releaseDate[i] < now) {
                tokenAuctionBeginTimestamp[tokens[i]] = now;
            } else {
                tokenAuctionBeginTimestamp[tokens[i]] = _releaseDate[i];
            }

            emit AddTokenV3(
                tokens[i],
                _patronageNumerator[i],
                tokenAuctionBeginTimestamp[tokens[i]]
            );
            // Adding this after the add token emit, so graph can first capture the token before processing the change artist things
            if (_artists.length > i) {
                changeArtistAddressAndCommission(
                    tokens[i],
                    _artists[i],
                    _artistCommission[i]
                );
            }
        }
    }

    function upgradeToV3(
        uint256[] memory tokens,
        address _withdrawCheckerAdmin,
        uint256 _auctionStartPrice,
        uint256 _auctionEndPrice,
        uint256 _auctionLength
    ) public notNullAddress(_withdrawCheckerAdmin) {
        emit UpgradeToV3();
        // This function effectively needs to call both _collectPatronage and _collectPatronagePatron from the v2 contract.
        require(withdrawCheckerAdmin == address(0));
        withdrawCheckerAdmin = _withdrawCheckerAdmin;
        // For each token
        for (uint8 i = 0; i < tokens.length; ++i) {
            uint256 tokenId = tokens[i];
            address currentOwner = assetToken.ownerOf(tokenId);

            uint256 timeSinceTokenLastCollection = now.sub(
                deprecated_timeLastCollected[tokenId]
            );

            // NOTE: for this upgrade we make sure no tokens are foreclosed, or close to foreclosing
            uint256 collection = price[tokenId]
                .mul(timeSinceTokenLastCollection)
                .mul(patronageNumerator[tokenId])
                .div(yearTimePatronagDenominator);

            // set the timeLastCollectedPatron for that tokens owner to 'now'.
            // timeLastCollected[tokenId] = now; // This variable is depricated, no need to update it.
            if (timeLastCollectedPatron[currentOwner] < now) {
                // set subtract patronage owed for the Patron from their deposit.
                deposit[currentOwner] = deposit[currentOwner].sub(
                    patronageOwedPatron(currentOwner)
                );

                timeLastCollectedPatron[currentOwner] = now;
            }

            // Add the amount collected for current token to the benefactorFunds.
            benefactorFunds[benefactors[tokenId]] = benefactorFunds[benefactors[tokenId]]
                .add(collection);

            // Emit an event for the graph to pickup this action (the last time this event will ever be emited)
            emit CollectPatronage(
                tokenId,
                currentOwner,
                deposit[currentOwner],
                collection
            );

            // mint required loyalty tokens
            mintManager.tokenMint(
                currentOwner,
                timeSinceTokenLastCollection, // this should always be > 0
                globalTokenGenerationRate // instead of this -> tokenGenerationRate[tokenId] hard code to save gas
            );
            emit CollectLoyalty(
                currentOwner,
                timeSinceTokenLastCollection.mul(globalTokenGenerationRate)
            ); // OPTIMIZE ME

            // Add the tokens generation rate to the totalPatronTokenGenerationRate of the current owner
            totalPatronTokenGenerationRate[currentOwner] = totalPatronTokenGenerationRate[currentOwner]
                .add(globalTokenGenerationRate);

            address tokenBenefactor = benefactors[tokenId];
            // add the scaled tokens price to the `totalBenefactorTokenNumerator`
            totalBenefactorTokenNumerator[tokenBenefactor] = totalBenefactorTokenNumerator[tokenBenefactor]
                .add(price[tokenId].mul(patronageNumerator[tokenId]));

            if (timeLastCollectedBenefactor[tokenBenefactor] == 0) {
                timeLastCollectedBenefactor[tokenBenefactor] = now;
            }
        }
        _changeAuctionParameters(
            _auctionStartPrice,
            _auctionEndPrice,
            _auctionLength
        );
    }

    function changeReceivingBenefactor(
        uint256 tokenId,
        address payable _newReceivingBenefactor
    )
        public
        onlyReceivingBenefactorOrAdmin(tokenId)
        updateBenefactorBalance(benefactors[tokenId])
        updateBenefactorBalance(_newReceivingBenefactor)
        notNullAddress(_newReceivingBenefactor)
    {
        address oldBenfactor = benefactors[tokenId];

        require(
            oldBenfactor != _newReceivingBenefactor,
            "cannot be same address"
        );

        // Collect patronage from old and new benefactor before changing totalBenefactorTokenNumerator on both
        uint256 scaledPrice = price[tokenId].mul(patronageNumerator[tokenId]);
        totalBenefactorTokenNumerator[oldBenfactor] = totalBenefactorTokenNumerator[oldBenfactor]
            .sub(scaledPrice);
        totalBenefactorTokenNumerator[_newReceivingBenefactor] = totalBenefactorTokenNumerator[_newReceivingBenefactor]
            .add(scaledPrice);

        benefactors[tokenId] = _newReceivingBenefactor;
        // NB No fund exchanging here please!
    }

    // NB This function is if an organisation loses their keys etc..
    // It will transfer their deposit to their new benefactor address
    // It should only be called once all their tokens also changeReceivingBenefactor
    function changeReceivingBenefactorDeposit(
        address oldBenfactor,
        address payable _newReceivingBenefactor
    )
        public
        onlyAdmin
        notNullAddress(_newReceivingBenefactor)
        notSameAddress(oldBenfactor, _newReceivingBenefactor)
    {
        require(benefactorFunds[oldBenfactor] > 0, "no funds");

        benefactorFunds[_newReceivingBenefactor] = benefactorFunds[_newReceivingBenefactor]
            .add(benefactorFunds[oldBenfactor]);
        benefactorFunds[oldBenfactor] = 0;
    }

    function changeAdmin(address _admin) public onlyAdmin {
        admin = _admin;
    }

    function changeWithdrawCheckerAdmin(address _withdrawCheckerAdmin)
        public
        onlyAdmin
        notNullAddress(_withdrawCheckerAdmin)
    {
        withdrawCheckerAdmin = _withdrawCheckerAdmin;
    }

    function changeArtistAddressAndCommission(
        uint256 tokenId,
        address artistAddress,
        uint256 percentage
    ) public onlyAdmin {
        require(percentage <= 200000, "not more than 20%");
        artistPercentages[tokenId] = percentage;
        artistAddresses[tokenId] = artistAddress;
        emit ArtistCommission(tokenId, artistAddress, percentage);
    }

    function _changeAuctionParameters(
        uint256 _auctionStartPrice,
        uint256 _auctionEndPrice,
        uint256 _auctionLength
    ) internal {
        require(
            _auctionStartPrice >= _auctionEndPrice,
            "auction start < auction end"
        );
        require(_auctionLength >= 86400, "1 day min auction length");

        auctionStartPrice = _auctionStartPrice;
        auctionEndPrice = _auctionEndPrice;
        auctionLength = _auctionLength;
        emit ChangeAuctionParameters();
    }

    function changeAuctionParameters(
        uint256 _auctionStartPrice,
        uint256 _auctionEndPrice,
        uint256 _auctionLength
    ) external onlyAdmin {
        _changeAuctionParameters(
            _auctionStartPrice,
            _auctionEndPrice,
            _auctionLength
        );
    }

    function patronageOwedPatron(address tokenPatron)
        public
        view
        returns (uint256 patronageDue)
    {
        // NOTE: Leaving this code here as a reminder: totalPatronOwnedTokenCost[tokenPatron] has to be zero if timeLastCollectedPatron[tokenPatron] is zero. So effectively this line isn't needed.
        // if (timeLastCollectedPatron[tokenPatron] == 0) return 0;
        return
            totalPatronOwnedTokenCost[tokenPatron]
                .mul(now.sub(timeLastCollectedPatron[tokenPatron]))
                .div(yearTimePatronagDenominator);
    }

    function patronageDueBenefactor(address benefactor)
        public
        view
        returns (uint256 payoutDue)
    {
        // NOTE: Leaving this code here as a reminder: totalBenefactorTokenNumerator[tokenPatron] has to be zero if timeLastCollectedBenefactor[tokenPatron] is zero. So effectively this line isn't needed.
        // if (timeLastCollectedBenefactor[benefactor] == 0) return 0;
        return
            totalBenefactorTokenNumerator[benefactor]
                .mul(now.sub(timeLastCollectedBenefactor[benefactor]))
                .div(yearTimePatronagDenominator);
    }

    function foreclosedPatron(address tokenPatron) public view returns (bool) {
        if (patronageOwedPatron(tokenPatron) >= deposit[tokenPatron]) {
            return true;
        } else {
            return false;
        }
    }

    function foreclosed(uint256 tokenId) public view returns (bool) {
        address tokenPatron = assetToken.ownerOf(tokenId);
        return foreclosedPatron(tokenPatron);
    }

    function depositAbleToWithdraw(address tokenPatron)
        public
        view
        returns (uint256)
    {
        uint256 collection = patronageOwedPatron(tokenPatron);
        if (collection >= deposit[tokenPatron]) {
            return 0;
        } else {
            return deposit[tokenPatron].sub(collection);
        }
    }

    function foreclosureTimePatron(address tokenPatron)
        public
        view
        returns (uint256)
    {
        uint256 pps = totalPatronOwnedTokenCost[tokenPatron].div(
            yearTimePatronagDenominator
        );
        return now.add(depositAbleToWithdraw(tokenPatron).div(pps));
    }

    function foreclosureTime(uint256 tokenId) public view returns (uint256) {
        address tokenPatron = assetToken.ownerOf(tokenId);
        return foreclosureTimePatron(tokenPatron);
    }

    /* actions */
    function _collectLoyaltyPatron(
        address tokenPatron,
        uint256 timeSinceLastMint
    ) internal {
        if (timeSinceLastMint != 0) {
            mintManager.tokenMint(
                tokenPatron,
                timeSinceLastMint,
                totalPatronTokenGenerationRate[tokenPatron]
            );
            emit CollectLoyalty(
                tokenPatron,
                timeSinceLastMint.mul(
                    totalPatronTokenGenerationRate[tokenPatron]
                )
            );
        }
    }

    // TODO: create a version of this function that only collects patronage (and only settles the benefactor if the token forecloses) - is this needed?

    function _collectPatronageAndSettleBenefactor(uint256 tokenId) public {
        address tokenPatron = assetToken.ownerOf(tokenId);
        uint256 newTimeLastCollectedOnForeclosure = _collectPatronagePatron(
            tokenPatron
        );

        address benefactor = benefactors[tokenId];
        // bool tokenForeclosed = newTimeLastCollectedOnForeclosure > 0;
        bool tokenIsOwned = state[tokenId] == StewardState.Owned;
        if (newTimeLastCollectedOnForeclosure > 0 && tokenIsOwned) {
            tokenAuctionBeginTimestamp[tokenId] =
                // The auction starts the second after the last time collected.
                newTimeLastCollectedOnForeclosure +
                1;


                uint256 patronageDueBenefactorBeforeForeclosure
             = patronageDueBenefactor(benefactor);

            _foreclose(tokenId);

            uint256 amountOverCredited = price[tokenId]
                .mul(now.sub(newTimeLastCollectedOnForeclosure))
                .mul(patronageNumerator[tokenId])
                .div(yearTimePatronagDenominator);

            if (amountOverCredited < patronageDueBenefactorBeforeForeclosure) {
                _increaseBenefactorBalance(
                    benefactor,
                    patronageDueBenefactorBeforeForeclosure - amountOverCredited
                );
            } else {
                _decreaseBenefactorBalance(
                    benefactor,
                    amountOverCredited - patronageDueBenefactorBeforeForeclosure
                );
            }

            timeLastCollectedBenefactor[benefactor] = now;
        } else {
            _updateBenefactorBalance(benefactor);
        }
    }

    function safeSend(uint256 _wei, address payable recipient)
        internal
        returns (bool transferSuccess)
    {
        (transferSuccess, ) = recipient.call.gas(2300).value(_wei)("");
    }

    // if credit balance exists,
    // if amount owed > creidt
    // credit zero add amount
    // else reduce credit by certain amount.
    // else if credit balance doesn't exist
    // add amount to balance

    function _updateBenefactorBalance(address benefactor) public {
        uint256 patronageDueBenefactor = patronageDueBenefactor(benefactor);

        if (patronageDueBenefactor > 0) {
            _increaseBenefactorBalance(benefactor, patronageDueBenefactor);
        }

        timeLastCollectedBenefactor[benefactor] = now;
    }

    function _increaseBenefactorBalance(
        address benefactor,
        uint256 patronageDueBenefactor
    ) internal {
        if (benefactorCredit[benefactor] > 0) {
            if (patronageDueBenefactor < benefactorCredit[benefactor]) {
                benefactorCredit[benefactor] = benefactorCredit[benefactor].sub(
                    patronageDueBenefactor
                );
            } else {
                benefactorFunds[benefactor] = patronageDueBenefactor.sub(
                    benefactorCredit[benefactor]
                );
                benefactorCredit[benefactor] = 0;
            }
        } else {
            benefactorFunds[benefactor] = benefactorFunds[benefactor].add(
                patronageDueBenefactor
            );
        }
    }

    function _decreaseBenefactorBalance(
        address benefactor,
        uint256 amountOverCredited
    ) internal {
        if (benefactorFunds[benefactor] > 0) {
            if (amountOverCredited <= benefactorFunds[benefactor]) {
                benefactorFunds[benefactor] = benefactorFunds[benefactor].sub(
                    amountOverCredited
                );
            } else {
                benefactorCredit[benefactor] = amountOverCredited.sub(
                    benefactorFunds[benefactor]
                );
                benefactorFunds[benefactor] = 0;
            }
        } else {
            benefactorCredit[benefactor] = benefactorCredit[benefactor].add(
                amountOverCredited
            );
        }
    }

    function fundsDueForAuctionPeriodAtCurrentRate(address benefactor)
        internal
        view
        returns (uint256)
    {
        return
            totalBenefactorTokenNumerator[benefactor].mul(auctionLength).div(
                yearTimePatronagDenominator
            ); // 365 days * 1000000000000
    }

    function withdrawBenefactorFundsTo(address payable benefactor) public {
        _updateBenefactorBalance(benefactor);

        uint256 availableToWithdraw = benefactorFunds[benefactor];


            uint256 benefactorWithdrawalSafetyDiscount
         = fundsDueForAuctionPeriodAtCurrentRate(benefactor);

        require(
            availableToWithdraw > benefactorWithdrawalSafetyDiscount,
            "no funds"
        );

        // NOTE: no need for safe-maths, above require prevents issues.
        uint256 amountToWithdraw = availableToWithdraw -
            benefactorWithdrawalSafetyDiscount;

        benefactorFunds[benefactor] = benefactorWithdrawalSafetyDiscount;
        if (safeSend(amountToWithdraw, benefactor)) {
            emit WithdrawBenefactorFundsWithSafetyDelay(
                benefactor,
                amountToWithdraw
            );
        } else {
            benefactorFunds[benefactor] = benefactorFunds[benefactor].add(
                amountToWithdraw
            );
        }
    }

    function hasher(
        address benefactor,
        uint256 maxAmount,
        uint256 expiry
    ) public view returns (bytes32) {
        // In ethereum you have to prepend all signature hashes with this message (supposedly to prevent people from)
        return
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    keccak256(abi.encodePacked(benefactor, maxAmount, expiry))
                )
            );
    }

    function withdrawBenefactorFundsToValidated(
        address payable benefactor,
        uint256 maxAmount,
        uint256 expiry,
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(
            ecrecover(hash, v, r, s) == withdrawCheckerAdmin,
            "no permission to withdraw"
        );
        require(
            hash == hasher(benefactor, maxAmount, expiry),
            "incorrect hash"
        );
        require(now < expiry, "coupon expired");

        _updateBenefactorBalance(benefactor);

        uint256 availableToWithdraw = benefactorFunds[benefactor];

        if (availableToWithdraw > 0) {
            if (availableToWithdraw > maxAmount) {
                if (safeSend(maxAmount, benefactor)) {
                    benefactorFunds[benefactor] = availableToWithdraw.sub(
                        maxAmount
                    );
                    emit WithdrawBenefactorFunds(
                        benefactor,
                        availableToWithdraw
                    );
                }
            } else {
                if (safeSend(availableToWithdraw, benefactor)) {
                    benefactorFunds[benefactor] = 0;
                    emit WithdrawBenefactorFunds(
                        benefactor,
                        availableToWithdraw
                    );
                }
            }
        }
    }

    function _collectPatronagePatron(address tokenPatron)
        public
        returns (uint256 newTimeLastCollectedOnForeclosure)
    {
        uint256 patronageOwedByTokenPatron = patronageOwedPatron(tokenPatron);

        uint256 timeSinceLastMint;

        if (
            patronageOwedByTokenPatron > 0 &&
            patronageOwedByTokenPatron > deposit[tokenPatron]
        ) {

                uint256 previousCollectionTime
             = timeLastCollectedPatron[tokenPatron];
            newTimeLastCollectedOnForeclosure = previousCollectionTime.add(
                (
                    (now.sub(previousCollectionTime))
                        .mul(deposit[tokenPatron])
                        .div(patronageOwedByTokenPatron)
                )
            );
            timeLastCollectedPatron[tokenPatron] = newTimeLastCollectedOnForeclosure;
            deposit[tokenPatron] = 0;
            timeSinceLastMint = (
                newTimeLastCollectedOnForeclosure.sub(previousCollectionTime)
            );
        } else {
            timeSinceLastMint = now.sub(timeLastCollectedPatron[tokenPatron]);
            timeLastCollectedPatron[tokenPatron] = now;
            deposit[tokenPatron] = deposit[tokenPatron].sub(
                patronageOwedByTokenPatron
            );
        }

        _collectLoyaltyPatron(tokenPatron, timeSinceLastMint);
        emit RemainingDepositUpdate(tokenPatron, deposit[tokenPatron]);
    }

    function depositWei() public payable {
        depositWeiPatron(msg.sender);
    }

    function depositWeiPatron(address patron) public payable {
        require(totalPatronOwnedTokenCost[patron] > 0, "no tokens");
        deposit[patron] = deposit[patron].add(msg.value);
        emit RemainingDepositUpdate(patron, deposit[patron]);
    }

    function _auctionPrice(uint256 tokenId) internal view returns (uint256) {
        uint256 auctionEnd = tokenAuctionBeginTimestamp[tokenId].add(
            auctionLength
        );

        // If it is not brand new and foreclosed, use the foreclosre auction price.
        uint256 _auctionStartPrice;
        if (price[tokenId] != 0 && price[tokenId] > auctionEndPrice) {
            _auctionStartPrice = price[tokenId];
        } else {
            // Otherwise use starting auction price
            _auctionStartPrice = auctionStartPrice;
        }

        if (now >= auctionEnd) {
            return auctionEndPrice;
        } else {
            // startPrice - ( ( (startPrice - endPrice) * howLongThisAuctionBeenGoing ) / auctionLength )
            return
                _auctionStartPrice.sub(
                    (_auctionStartPrice.sub(auctionEndPrice))
                        .mul(now.sub(tokenAuctionBeginTimestamp[tokenId]))
                        .div(auctionLength)
                );
        }
    }

    function buy(
        uint256 tokenId,
        uint256 _newPrice,
        uint256 previousPrice,
        uint256 wildcardsPercentage
    )
        public
        payable
        collectPatronageAndSettleBenefactor(tokenId)
        collectPatronagePatron(msg.sender)
        priceGreaterThanZero(_newPrice)
        youCurrentlyAreNotInDefault(msg.sender)
        validWildcardsPercentage(wildcardsPercentage, tokenId)
    {
        require(state[tokenId] == StewardState.Owned, "token on auction");
        require(
            price[tokenId] == previousPrice,
            "must specify current price accurately"
        );

        _distributePurchaseProceeds(tokenId);

        wildcardsPercentages[tokenId] = wildcardsPercentage;
        uint256 remainingValueForDeposit = msg.value.sub(price[tokenId]);
        deposit[msg.sender] = deposit[msg.sender].add(remainingValueForDeposit);
        transferAssetTokenTo(
            tokenId,
            assetToken.ownerOf(tokenId),
            msg.sender,
            _newPrice
        );
        emit Buy(tokenId, msg.sender, _newPrice);
    }

    function buyAuction(
        uint256 tokenId,
        uint256 _newPrice,
        uint256 wildcardsPercentage
    )
        public
        payable
        collectPatronageAndSettleBenefactor(tokenId)
        collectPatronagePatron(msg.sender)
        priceGreaterThanZero(_newPrice)
        youCurrentlyAreNotInDefault(msg.sender)
        validWildcardsPercentage(wildcardsPercentage, tokenId)
    {
        require(
            state[tokenId] == StewardState.Foreclosed,
            "token not foreclosed"
        );
        require(now >= tokenAuctionBeginTimestamp[tokenId], "not on auction");
        uint256 auctionTokenPrice = _auctionPrice(tokenId);
        uint256 remainingValueForDeposit = msg.value.sub(auctionTokenPrice);

        _distributeAuctionProceeds(tokenId);

        state[tokenId] = StewardState.Owned;

        wildcardsPercentages[tokenId] = wildcardsPercentage;
        deposit[msg.sender] = deposit[msg.sender].add(remainingValueForDeposit);
        transferAssetTokenTo(
            tokenId,
            assetToken.ownerOf(tokenId),
            msg.sender,
            _newPrice
        );
        emit Buy(tokenId, msg.sender, _newPrice);
    }

    function _distributeAuctionProceeds(uint256 tokenId) internal {
        uint256 totalAmount = price[tokenId];
        uint256 artistAmount;
        if (artistPercentages[tokenId] == 0) {
            artistAmount = 0;
        } else {
            artistAmount = totalAmount.mul(artistPercentages[tokenId]).div(
                1000000
            );
            deposit[artistAddresses[tokenId]] = deposit[artistAddresses[tokenId]]
                .add(artistAmount);
        }
        uint256 wildcardsAmount = totalAmount.sub(artistAmount);
        deposit[admin] = deposit[admin].add(wildcardsAmount);
    }

    function _distributePurchaseProceeds(uint256 tokenId) internal {
        uint256 totalAmount = price[tokenId];
        address tokenPatron = assetToken.ownerOf(tokenId);
        // Wildcards percentage calc
        if (wildcardsPercentages[tokenId] == 0) {
            wildcardsPercentages[tokenId] = 50000;
        }
        uint256 wildcardsAmount = totalAmount
            .mul(wildcardsPercentages[tokenId])
            .div(1000000);

        // Artist percentage calc
        uint256 artistAmount;
        if (artistPercentages[tokenId] == 0) {
            artistAmount = 0;
        } else {
            artistAmount = totalAmount.mul(artistPercentages[tokenId]).div(
                1000000
            );
            deposit[artistAddresses[tokenId]] = deposit[artistAddresses[tokenId]]
                .add(artistAmount);
        }

        uint256 previousOwnerProceedsFromSale = totalAmount
            .sub(wildcardsAmount)
            .sub(artistAmount);
        if (
            totalPatronOwnedTokenCost[tokenPatron] ==
            price[tokenId].mul(patronageNumerator[tokenId])
        ) {
            previousOwnerProceedsFromSale = previousOwnerProceedsFromSale.add(
                deposit[tokenPatron]
            );
            deposit[tokenPatron] = 0;
            address payable payableCurrentPatron = address(
                uint160(tokenPatron)
            );
            (bool transferSuccess, ) = payableCurrentPatron
                .call
                .gas(2300)
                .value(previousOwnerProceedsFromSale)("");
            if (!transferSuccess) {
                deposit[tokenPatron] = deposit[tokenPatron].add(
                    previousOwnerProceedsFromSale
                );
            }
        } else {
            deposit[tokenPatron] = deposit[tokenPatron].add(
                previousOwnerProceedsFromSale
            );
        }

        deposit[admin] = deposit[admin].add(wildcardsAmount);
    }

    function changePrice(uint256 tokenId, uint256 _newPrice)
        public
        onlyPatron(tokenId)
        collectPatronageAndSettleBenefactor(tokenId)
    {
        require(state[tokenId] != StewardState.Foreclosed, "foreclosed");
        require(_newPrice != 0, "incorrect price");
        require(_newPrice < 10000 ether, "exceeds max price");

        uint256 oldPriceScaled = price[tokenId].mul(
            patronageNumerator[tokenId]
        );
        uint256 newPriceScaled = _newPrice.mul(patronageNumerator[tokenId]);
        address tokenBenefactor = benefactors[tokenId];

        totalPatronOwnedTokenCost[msg.sender] = totalPatronOwnedTokenCost[msg
            .sender]
            .sub(oldPriceScaled)
            .add(newPriceScaled);

        totalBenefactorTokenNumerator[tokenBenefactor] = totalBenefactorTokenNumerator[tokenBenefactor]
            .sub(oldPriceScaled)
            .add(newPriceScaled);

        price[tokenId] = _newPrice;
        emit PriceChange(tokenId, price[tokenId]);
    }

    function withdrawDeposit(uint256 _wei)
        public
        collectPatronagePatron(msg.sender)
        returns (uint256)
    {
        _withdrawDeposit(_wei);
    }

    function withdrawBenefactorFunds() public {
        withdrawBenefactorFundsTo(msg.sender);
    }

    function exit() public collectPatronagePatron(msg.sender) {
        _withdrawDeposit(deposit[msg.sender]);
    }

    function _withdrawDeposit(uint256 _wei) internal {
        require(deposit[msg.sender] >= _wei, "withdrawing too much");

        deposit[msg.sender] = deposit[msg.sender].sub(_wei);

        (bool transferSuccess, ) = msg.sender.call.gas(2300).value(_wei)("");
        if (!transferSuccess) {
            revert("withdrawal failed");
        }
    }

    function _foreclose(uint256 tokenId) internal {
        address currentOwner = assetToken.ownerOf(tokenId);
        resetTokenOnForeclosure(tokenId, currentOwner);
        state[tokenId] = StewardState.Foreclosed;

        emit Foreclosure(currentOwner, timeLastCollectedPatron[currentOwner]);
    }

    function transferAssetTokenTo(
        uint256 tokenId,
        address _currentOwner,
        address _newOwner,
        uint256 _newPrice
    ) internal {
        require(_newPrice < 10000 ether, "exceeds max price");

        uint256 scaledOldPrice = price[tokenId].mul(
            patronageNumerator[tokenId]
        );
        uint256 scaledNewPrice = _newPrice.mul(patronageNumerator[tokenId]);

        totalPatronOwnedTokenCost[_newOwner] = totalPatronOwnedTokenCost[_newOwner]
            .add(scaledNewPrice);
        totalPatronTokenGenerationRate[_newOwner] = totalPatronTokenGenerationRate[_newOwner]
            .add(globalTokenGenerationRate);

        address tokenBenefactor = benefactors[tokenId];
        totalBenefactorTokenNumerator[tokenBenefactor] = totalBenefactorTokenNumerator[tokenBenefactor]
            .add(scaledNewPrice);

        if (_currentOwner != address(this) && _currentOwner != address(0)) {
            totalPatronOwnedTokenCost[_currentOwner] = totalPatronOwnedTokenCost[_currentOwner]
                .sub(scaledOldPrice);

            totalPatronTokenGenerationRate[_currentOwner] = totalPatronTokenGenerationRate[_currentOwner]
                .sub(globalTokenGenerationRate);

            totalBenefactorTokenNumerator[tokenBenefactor] = totalBenefactorTokenNumerator[tokenBenefactor]
                .sub(scaledOldPrice);
        }

        assetToken.transferFrom(_currentOwner, _newOwner, tokenId);

        price[tokenId] = _newPrice;
    }

    function resetTokenOnForeclosure(uint256 tokenId, address _currentOwner)
        internal
    {
        uint256 scaledPrice = price[tokenId].mul(patronageNumerator[tokenId]);

        totalPatronOwnedTokenCost[_currentOwner] = totalPatronOwnedTokenCost[_currentOwner]
            .sub(scaledPrice);

        totalPatronTokenGenerationRate[_currentOwner] = totalPatronTokenGenerationRate[_currentOwner]
            .sub((globalTokenGenerationRate));

        address tokenBenefactor = benefactors[tokenId];
        totalBenefactorTokenNumerator[tokenBenefactor] = totalBenefactorTokenNumerator[tokenBenefactor]
            .sub(scaledPrice);

        assetToken.transferFrom(_currentOwner, address(this), tokenId);
    }
}
