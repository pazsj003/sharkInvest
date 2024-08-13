// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

import {ICloneFactory} from "../lib/CloneFactory.sol";
import "./D3VaultStorage.sol";
import "../../intf/ID3Oracle.sol";
import "../intf/ID3UserQuota.sol";
import "../intf/ID3PoolQuota.sol";
import "../intf/ID3MM.sol";
import "../intf/IDToken.sol";
import "../intf/ID3RateManager.sol";

/// @title D3VaultFunding
/// @notice This contract defines the fund management of D3Vault.
/// @notice Users (LP) deposit funds into vault to earn interests; D3Pools borrows funds from vault to make market.
/// @notice Part of the borrow interests will become the reserve fund.
/// @notice The borrow interest rate is dynamicly changing with fund utilization ratio, and is caculated by D3RateManager.
/// @notice The fund utilization ratio is defined as U = borrows / (cash + borrows - reserves)
/// @notice Users who deposit funds into vault will receive certain amounts of corresponding dToken. The amount is calculated by the exchange rate.
/// @notice The exchange rate between dToken and underlying token is defined as exchangeRate = (cash + totalBorrows -reserves) / dTokenSupply
/// @notice As time passes, totalBorrows will increase, so does the dToken exchangeRate. That's how users earn interests with dToken.
contract D3VaultFunding is D3VaultStorage {
    using SafeERC20 for IERC20;
    using DecimalMath for uint256;

    // ---------- LP user Fund ----------

    /// @notice user should transfer token to vault before call this function
    function userDeposit(
        address user,
        address token
    ) external nonReentrant allowedToken(token) returns (uint256 dTokenAmount) {
        accrueInterest(token);

        AssetInfo storage info = assetInfo[token];
        uint256 realBalance = IERC20(token).balanceOf(address(this));
        uint256 amount = realBalance - info.balance;
        if (!ID3UserQuota(_USER_QUOTA_).checkQuota(user, token, amount))
            revert Errors.D3VaultExceedQuota();
        uint256 exchangeRate = _getExchangeRate(token);
        uint256 totalDToken = IDToken(info.dToken).totalSupply();
        if (totalDToken.mul(exchangeRate) + amount > info.maxDepositAmount)
            revert Errors.D3VaultExceedMaxDepositAmount();
        dTokenAmount = amount.div(exchangeRate);

        if (totalDToken == 0) {
            // permanently lock a very small amount of dTokens into address(1), which reduces potential issues with rounding,
            // and also prevents the pool from ever being fully drained
            if (dTokenAmount <= DEFAULT_MINIMUM_DTOKEN)
                revert Errors.D3VaultMinimumDToken();
            IDToken(info.dToken).mint(address(1), DEFAULT_MINIMUM_DTOKEN);
            IDToken(info.dToken).mint(
                user,
                dTokenAmount - DEFAULT_MINIMUM_DTOKEN
            );
        } else {
            IDToken(info.dToken).mint(user, dTokenAmount);
        }

        info.balance = realBalance;

        emit UserDeposit(user, token, amount, dTokenAmount);
    }

    /// @param to who receive tokens
    /// @param user who pay dTokens
    /// @param token original token address
    /// @param dTokenAmount dtoken the token record amount
    function userWithdraw(
        address to,
        address user,
        address token,
        uint256 dTokenAmount
    ) external nonReentrant allowedToken(token) returns (uint256 amount) {
        accrueInterest(token);
        AssetInfo storage info = assetInfo[token];
        if (dTokenAmount > IDToken(info.dToken).balanceOf(msg.sender))
            revert Errors.D3VaultDTokenBalanceNotEnough();

        amount = dTokenAmount.mul(_getExchangeRate(token));
        IDToken(info.dToken).burn(msg.sender, dTokenAmount);
        IERC20(token).safeTransfer(to, amount);
        info.balance = info.balance - amount;

        // used for calculate user withdraw amount
        // this function could be called from d3Proxy, so we need "user" param
        // In the meantime, some users may hope to use this function directly,
        // to prevent these users fill "user" param with wrong addresses,
        // we use "msg.sender" param to check.
        emit UserWithdraw(msg.sender, user, token, amount, dTokenAmount);
    }

    // ---------- Pool Fund ----------
    function poolBorrow(
        address token,
        uint256 amount
    ) external nonReentrant allowedToken(token) onlyPool {
        uint256 quota = ID3PoolQuota(_POOL_QUOTA_).getPoolQuota(
            msg.sender,
            token
        );
        accrueInterest(token);
        //获取资产和借款记录：
        AssetInfo storage info = assetInfo[token];
        BorrowRecord storage record = info.borrowRecord[msg.sender];
        uint256 usedQuota = _borrowAmount(
            record.amount,
            record.interestIndex,
            info.borrowIndex
        ); // borrowAmount = record.amount * newIndex / oldIndex
        //确保借款总量不超过配额。
        if (amount + usedQuota > quota) revert Errors.D3VaultExceedQuota();
        //确保借款金额不超过可用余额。
        if (
            amount >
            info.balance - (info.totalReserves - info.withdrawnReserves)
        ) revert Errors.D3VaultAmountExceedVaultBalance();

        uint256 interests = usedQuota - record.amount;
        //更新借款记录
        if (record.amount == 0 && usedQuota + amount > 0) {
            borrowerCount++;
        }
        record.amount = usedQuota + amount;
        record.interestIndex = info.borrowIndex;
        info.totalBorrows = info.totalBorrows + amount;
        info.balance = info.balance - amount;

        //转移代币
        IERC20(token).safeTransfer(msg.sender, amount); // 从 D3vaultFunding 转给D3funding.sol

        emit PoolBorrow(msg.sender, token, amount, interests);
    }

    function poolRepay(
        address token,
        uint256 amount
    ) external nonReentrant allowedToken(token) onlyPool {
        /*
        poolOngoing 修饰符：确保 D3Funding 合约自身未处于清算状态。
        poolRepay 函数中的检查：确保调用该函数的池子未处于清算状态。
        */
        if (ID3MM(msg.sender).isInLiquidation())
            revert Errors.D3VaultAlreadyInLiquidation();
        //累计利息 update interest
        accrueInterest(token);
        //获取借款记录
        AssetInfo storage info = assetInfo[token];
        BorrowRecord storage record = info.borrowRecord[msg.sender];
        //计算当前借款金额：
        uint256 borrows = _borrowAmount(
            record.amount,
            record.interestIndex,
            info.borrowIndex
        ); // borrowAmount = record.amount * newIndex / oldIndex
        //检查还款金额是否超过借款金额：
        if (amount > borrows) revert Errors.D3VaultAmountExceed();

        uint256 interests = borrows - record.amount;
        //更新借款记录
        record.amount = borrows - amount;
        record.interestIndex = info.borrowIndex;
        //更新总借款量
        if (info.totalBorrows < amount) {
            info.totalBorrows = 0;
        } else {
            info.totalBorrows = info.totalBorrows - amount;
        }
        //更新借款者计数
        if (record.amount == 0) {
            borrowerCount--;
        }
        if (borrowerCount == 0) {
            info.totalBorrows = 0;
        }
        //增加余额
        info.balance = info.balance + amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount); //// 从D3funding.sol转给 D3vaultFunding

        emit PoolRepay(msg.sender, token, amount, interests);
    }

    function poolRepayAll(
        address token
    ) external nonReentrant allowedToken(token) onlyPool {
        if (ID3MM(msg.sender).isInLiquidation())
            revert Errors.D3VaultAlreadyInLiquidation();
        _poolRepayAll(msg.sender, token);
    }

    function _poolRepayAll(address pool, address token) internal {
        accrueInterest(token);

        AssetInfo storage info = assetInfo[token];
        BorrowRecord storage record = info.borrowRecord[pool];
        uint256 amount = _borrowAmount(
            record.amount,
            record.interestIndex,
            info.borrowIndex
        ); // borrowAmount = record.amount * newIndex / oldIndex

        uint256 interests = amount - record.amount;
        //更新借款记录
        record.amount = 0;
        record.interestIndex = info.borrowIndex;
        //更新总借款量
        if (info.totalBorrows < amount) {
            info.totalBorrows = 0;
        } else {
            info.totalBorrows = info.totalBorrows - amount;
        }
        borrowerCount--;
        if (borrowerCount == 0) {
            info.totalBorrows = 0;
        }
        info.balance = info.balance + amount;
        IERC20(token).safeTransferFrom(pool, address(this), amount);

        emit PoolRepay(pool, token, amount, interests);
    }

    // ---------- Interest ----------

    /// @notice Accrue interest for a token
    /// @notice Step1: get time past
    /// @notice Step2: get borrow rate
    /// @notice Step3: calculate compound interest rate during the past time
    /// @notice Step4: calculate increased borrows, reserves
    /// @notice Step5: update borrows, reserves, accrual time, borrowIndex
    /// @notice borrowIndex is the accrual interest rate
    function accrueInterestForRead(
        address token
    )
        public
        view
        returns (
            uint256 totalBorrowsNew,
            uint256 totalReservesNew,
            uint256 borrowIndexNew,
            uint256 accrualTime
        )
    {
        AssetInfo storage info = assetInfo[token];

        uint256 currentTime = block.timestamp;
        uint256 deltaTime = currentTime - info.accrualTime;
        if (deltaTime == 0)
            return (
                info.totalBorrows,
                info.totalReserves,
                info.borrowIndex,
                currentTime
            );

        uint256 borrowsPrior = info.totalBorrows;
        uint256 reservesPrior = info.totalReserves;
        uint256 borrowIndexPrior = info.borrowIndex;

        uint256 borrowRate = ID3RateManager(_RATE_MANAGER_).getBorrowRate(
            token,
            getUtilizationRatio(token)
        );
        uint256 borrowRatePerSecond = borrowRate / SECONDS_PER_YEAR;
        uint256 compoundInterestRate = getCompoundInterestRate(
            borrowRatePerSecond,
            deltaTime
        );
        totalBorrowsNew = borrowsPrior.mul(compoundInterestRate);
        totalReservesNew =
            reservesPrior +
            (totalBorrowsNew - borrowsPrior).mul(info.reserveFactor);
        borrowIndexNew = borrowIndexPrior.mul(compoundInterestRate);

        accrualTime = currentTime;
    }

    /// @notice Accrue interest for a token, change storage
    function accrueInterest(address token) public {
        // 更新assetInfo数据
        (
            assetInfo[token].totalBorrows,
            assetInfo[token].totalReserves,
            assetInfo[token].borrowIndex,
            assetInfo[token].accrualTime
        ) = accrueInterestForRead(token);
    }

    function accrueInterests() public {
        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];
            accrueInterest(token);
        }
    }

    /// @dev r: interest rate per second (decimals 18)
    /// @dev t: total time in seconds
    /// @dev 这个函数的目的是计算给定利率和时间段的复利利率。它使用了泰勒展开式（Taylor Series Expansion）来近似计算复利利率。
    /// 只取前面3项 (1+r)^t = 1 + rt + t*(t-1)*r^2/2! + t*(t-1)*(t-2)*r^3/3! + ... + t*(t-1)...*(t-n+1)*r^n/n!
    function getCompoundInterestRate(
        uint256 r,
        uint256 t
    ) public pure returns (uint256) {
        if (t < 1) {
            return 1e18;
        } else if (t < 2) {
            return 1e18 + r * t;
        } else {
            return 1e18 + r * t + (r.powFloor(2) * t * (t - 1)) / 2;
        }
    }

    // ----------- View ----------

    function getPoolLeftQuota(
        address pool,
        address token
    ) public view returns (uint256 leftQuota) {
        uint256 quota = ID3PoolQuota(_POOL_QUOTA_).getPoolQuota(pool, token);
        uint256 oldInterestIndex = assetInfo[token]
            .borrowRecord[pool]
            .interestIndex;
        (, , uint256 currentInterestIndex, ) = accrueInterestForRead(token);
        uint256 usedQuota = _borrowAmount(
            assetInfo[token].borrowRecord[pool].amount,
            oldInterestIndex,
            currentInterestIndex
        ); // borrowAmount = record.amount * newIndex / oldIndex
        leftQuota = quota > usedQuota ? quota - usedQuota : 0;
    }

    /// @notice U = borrows / (cash + borrows - reserves)
    function getUtilizationRatio(address token) public view returns (uint256) {
        uint256 borrows = getTotalBorrows(token);
        uint256 cash = getCash(token);
        uint256 reserves = getReservesInVault(token);
        if (borrows == 0) return 0;
        if (cash + borrows <= reserves) return 1e18; // Utilization Ratio is 100%
        return borrows.div(cash + borrows - reserves);
    }

    function getBorrowRate(address token) public view returns (uint256 rate) {
        rate = ID3RateManager(_RATE_MANAGER_).getBorrowRate(
            token,
            getUtilizationRatio(token)
        );
    }

    function getCash(address token) public view returns (uint256) {
        return assetInfo[token].balance;
    }

    function getTotalBorrows(address token) public view returns (uint256) {
        return assetInfo[token].totalBorrows;
    }

    function getReservesInVault(address token) public view returns (uint256) {
        AssetInfo storage info = assetInfo[token];
        return info.totalReserves - info.withdrawnReserves;
    }

    /// @notice exchangeRate = (cash + totalBorrows -reserves) / dTokenSupply
    /// @notice Make sure accrueInterests or accrueInterest(token) is called before
    function _getExchangeRate(address token) internal view returns (uint256) {
        AssetInfo storage info = assetInfo[token];
        uint256 cash = getCash(token);
        uint256 dTokenSupply = IERC20(info.dToken).totalSupply();
        if (dTokenSupply == 0) {
            return 1e18;
        }
        return
            (cash +
                info.totalBorrows -
                (info.totalReserves - info.withdrawnReserves)).div(
                    dTokenSupply
                );
    }

    /// @notice Make sure accrueInterests or accrueInterest(token) is called before
    function _getBalanceAndBorrows(
        address pool,
        address token
    ) internal view returns (uint256, uint256) {
        AssetInfo storage info = assetInfo[token];
        BorrowRecord storage record = info.borrowRecord[pool];

        uint256 balance = ID3MM(pool).getTokenReserve(token);
        uint256 borrows = _borrowAmount(
            record.amount,
            record.interestIndex,
            info.borrowIndex
        ); // borrowAmount = record.amount * newIndex / oldIndex

        return (balance, borrows);
    }

    /// @notice Make sure accrueInterests() is called before calling this function
    function _getTotalDebtValue(
        address pool
    ) internal view returns (uint256 totalDebt) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            AssetInfo storage info = assetInfo[token];
            BorrowRecord memory record = info.borrowRecord[pool];
            uint256 borrows = _borrowAmount(
                record.amount,
                record.interestIndex,
                info.borrowIndex
            ); // borrowAmount = record.amount * newIndex / oldIndex
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);
            totalDebt += borrows.mul(price);
        }
    }

    function getTotalAssetsValue(
        address pool
    ) public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);
            totalValue += DecimalMath.mul(
                ID3MM(pool).getTokenReserve(token),
                price
            );
        }
    }

    /// @notice Make sure accrueInterests() is called before
    /// @notice net = balance - borrowed
    /// @notice collateral = sum(min(positive net, maxCollateralAmount）* weight * price)
    /// @notice debt = sum(negative net * weight * price)
    /// @notice collateralRatio = collateral / debt
    function _getCollateralRatio(address pool) internal view returns (uint256) {
        uint256 collateral = 0;
        uint256 debt = 0;
        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];
            AssetInfo storage info = assetInfo[token];

            (uint256 balance, uint256 borrows) = _getBalanceAndBorrows(
                pool,
                token
            );
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);
            if (balance >= borrows) {
                collateral += min(balance - borrows, info.maxCollateralAmount)
                    .mul(info.collateralWeight)
                    .mul(price);
            } else {
                debt += (borrows - balance).mul(info.debtWeight).mul(price);
            }
        }
        return _ratioDiv(collateral, debt);
    }

    function checkSafe(address pool) public view returns (bool) {
        return getCollateralRatio(pool) > 1e18 + IM; // 大于这个值被认为这个池子的是安全的
    }

    function checkBorrowSafe(address pool) public view returns (bool) {
        return getCollateralRatioBorrow(pool) > IM;
    }

    function checkCanBeLiquidated(address pool) public view returns (bool) {
        return getCollateralRatio(pool) < 1e18 + MM;
    }

    function checkCanBeLiquidatedAfterAccrue(
        address pool
    ) public view returns (bool) {
        return _getCollateralRatio(pool) < 1e18 + MM;
    }

    function checkBadDebt(address pool) public view returns (bool) {
        uint256 totalAssetValue = getTotalAssetsValue(pool);
        uint256 totalDebtValue = getTotalDebtValue(pool);
        return totalAssetValue < totalDebtValue;
    }

    function checkBadDebtAfterAccrue(address pool) public view returns (bool) {
        uint256 totalAssetValue = getTotalAssetsValue(pool);
        uint256 totalDebtValue = _getTotalDebtValue(pool);
        return totalAssetValue < totalDebtValue;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }
    /*
   通过这种方式，getCollateralRatio 函数计算了资金池中所有代币的抵押品和债务的总价值，
   从而衡量资金池的健康状况。抵押率越高，资金池越安全；抵押率越低，资金池越有可能面临清算风险
   */
    function _ratioDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        //这种情况下，选择返回一个中性的值 1e18，即1，表示抵押率为1
        //这种设计的意图可能是为了确保资金池在完全没有抵押品和债务的情况下被认为是不安全的。
        //只有在有足够的抵押品（相对于债务）时，才会被认为是安全的。
        if (a == 0 && b == 0) {
            return 1e18;
            //逻辑：没有抵押品但有债务，返回 0。解释：这种情况下，抵押率为0，因为没有任何抵押品来支持债务。
        } else if (a == 0 && b != 0) {
            return 0;
            //逻辑：有抵押品但没有债务，返回 type(uint256).max。解释：这种情况下，抵押率极高，理论上接近无穷大，因为没有任何债务。
        } else if (a != 0 && b == 0) {
            return type(uint256).max;
        } else {
            return a.div(b);
        }
    }

    function _borrowAmount(
        uint256 amount,
        uint256 oldIndex,
        uint256 newIndex
    ) internal pure returns (uint256) {
        if (oldIndex == 0) {
            oldIndex = 1e18;
        }
        if (oldIndex > newIndex) {
            oldIndex = newIndex;
        }
        return (amount * newIndex) / oldIndex;
    }

    // =========  ============== Read Only =======================

    function getExchangeRate(
        address token
    ) public view returns (uint256 exchangeRate) {
        (
            uint256 totalBorrows,
            uint256 totalReserves,
            ,

        ) = accrueInterestForRead(token);
        uint256 cash = getCash(token);
        uint256 dTokenSupply = IERC20(assetInfo[token].dToken).totalSupply();
        if (dTokenSupply == 0) {
            return 1e18;
        }
        exchangeRate = (cash +
            totalBorrows -
            (totalReserves - assetInfo[token].withdrawnReserves)).div(
                dTokenSupply
            );
    }

    function getLatestBorrowIndex(
        address token
    ) public view returns (uint256 borrowIndex) {
        AssetInfo storage info = assetInfo[token];
        uint256 deltaTime = block.timestamp - info.accrualTime;
        uint256 borrowRate = getBorrowRate(token);
        uint256 borrowRatePerSecond = borrowRate / SECONDS_PER_YEAR;
        uint256 compoundInterestRate = getCompoundInterestRate(
            borrowRatePerSecond,
            deltaTime
        );
        borrowIndex = info.borrowIndex.mul(compoundInterestRate);
    }

    function getPoolBorrowAmount(
        address pool,
        address token
    ) public view returns (uint256 amount) {
        BorrowRecord storage record = assetInfo[token].borrowRecord[pool];
        uint256 borrowIndex = getLatestBorrowIndex(token);
        amount = _borrowAmount(
            record.amount,
            record.interestIndex,
            borrowIndex
        ); // borrowAmount = record.amount * newIndex / oldIndex
    }

    function getTotalDebtValue(
        address pool
    ) public view returns (uint256 totalDebt) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            uint256 borrowAmount = getPoolBorrowAmount(pool, token);
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);
            totalDebt += borrowAmount.mul(price);
        }
    }

    function getBalanceAndBorrows(
        address pool,
        address token
    ) public view returns (uint256, uint256) {
        uint256 balance = ID3MM(pool).getTokenReserve(token);
        uint256 borrows = getPoolBorrowAmount(pool, token);
        return (balance, borrows);
    }

    function getCollateralRatio(address pool) public view returns (uint256) {
        uint256 collateral = 0;
        uint256 debt = 0;
        // 算所有代币的 抵押跟 借贷的总和
        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];
            AssetInfo storage info = assetInfo[token];

            (uint256 balance, uint256 borrows) = getBalanceAndBorrows(
                pool,
                token
            );
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);

            if (balance >= borrows) {
                //min(balance - borrows, info.maxCollateralAmount)：
                //确保抵押品数量不超过允许的最大抵押数量。即使余额减去借款的数量很大，抵押品数量也不会超过info.maxCollateralAmount。
                collateral += min(balance - borrows, info.maxCollateralAmount)
                    .mul(info.collateralWeight)
                    .mul(price);
            } else {
                debt += (borrows - balance).mul(info.debtWeight).mul(price);
            }
        }
        return _ratioDiv(collateral, debt);
    }

    /// @notice collateralRatioBorrow = ∑[min(maxCollateralAmount，balance - borrows）] / ∑borrows
    function getCollateralRatioBorrow(
        address pool
    ) public view returns (uint256) {
        uint256 balanceSumPositive = 0;
        uint256 balanceSumNegative = 0;
        uint256 borrowedSum = 0;
        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];

            (uint256 balance, uint256 borrows) = getBalanceAndBorrows(
                pool,
                token
            );
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);

            if (balance >= borrows) {
                balanceSumPositive += min(
                    balance - borrows,
                    assetInfo[token].maxCollateralAmount
                ).mul(price);
            } else {
                balanceSumNegative += (borrows - balance).mul(price);
            }
            //计算抵押价值与借款价值的比率，反映池子的健康状态
            borrowedSum += borrows.mul(price);
        }
        //计算最终的抵押价值总和
        uint256 balanceSum = balanceSumPositive < balanceSumNegative
            ? 0
            : balanceSumPositive - balanceSumNegative;
        //计算净抵押价值与总借款价值的比率。
        return _ratioDiv(balanceSum, borrowedSum);
    }

    function getCumulativeBorrowRate(
        address pool,
        address token
    ) external view returns (uint256 cumulativeRate, uint256 currentAmount) {
        BorrowRecord storage record = assetInfo[token].borrowRecord[pool];
        uint256 borrowIndex = getLatestBorrowIndex(token);
        cumulativeRate = borrowIndex.div(
            record.interestIndex == 0 ? 1e18 : record.interestIndex
        );
        currentAmount = record.amount;
    }

    function buySharkDeposit(
        address user,
        address token,
        uint8 range,
        uint256 baseInterest,
        uint256 lowInterestRate,
        uint256 highInterestRate,
        uint256 lowPrice,
        uint256 highPrice
    )
        external
        nonReentrant
        allowedSharkToken(token)
        returns (uint256 dTokenAmount)
    {
        // 钱提前打进去， 但没有利息计算环节， 而且这个资金跟之前的userDeposit 渠道不同
        sharkInterest(
            range,
            baseInterest,
            lowInterestRate,
            highInterestRate,
            lowPrice,
            highPrice
        );
        AssetInfo storage info = assetInfo[token];
        uint256 realBalance = IERC20(token).balanceOf(address(this));
        uint256 amount = realBalance - info.balance;
        if (!ID3UserQuota(_USER_QUOTA_).checkQuota(user, token, amount))
            revert Errors.D3VaultExceedQuota();
        uint256 exchangeRate = _getExchangeRate(token);
        uint256 totalDToken = IDToken(info.dToken).totalSupply();
        if (totalDToken.mul(exchangeRate) + amount > info.maxDepositAmount)
            revert Errors.D3VaultExceedMaxDepositAmount();
        dTokenAmount = amount.div(exchangeRate);

        if (totalDToken == 0) {
            // permanently lock a very small amount of dTokens into address(1), which reduces potential issues with rounding,
            // and also prevents the pool from ever being fully drained
            if (dTokenAmount <= DEFAULT_MINIMUM_DTOKEN)
                revert Errors.D3VaultMinimumDToken();
            IDToken(info.dToken).mint(address(1), DEFAULT_MINIMUM_DTOKEN);
            IDToken(info.dToken).mint(
                user,
                dTokenAmount - DEFAULT_MINIMUM_DTOKEN
            );
        } else {
            IDToken(info.dToken).mint(user, dTokenAmount);
        }

        info.balance = realBalance;

        emit UserDeposit(user, token, amount, dTokenAmount);
    }
    // 内部鲨鱼鳍的一些函数需要放， 然后通过d3proxy 来
    // 产品申购 - 锁定计息 - 到期结算 - 还本付息 这个利息跟直接存入的利息不同的计算方式，因为这个短期内不取出来
}
