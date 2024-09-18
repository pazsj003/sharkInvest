/*

    Copyright 2020 DODO ZOO.
    SPDX-License-Identifier: Apache-2.0

*/

pragma solidity 0.8.16;

interface ID3Vault {
    function tokens(address) external view returns (bool);
    function _ORACLE_() external view returns (address);
    function allPoolAddrMap(address) external view returns (bool);
    function poolBorrow(address token, uint256 amount) external;
    function poolRepay(address token, uint256 bTokenAmount) external;
    function poolRepayAll(address token) external;
    function poolBorrowLpFee(address token, uint256 amount) external;
    function getBorrowed(
        address pool,
        address token
    ) external view returns (uint256);
    function getAssetInfo(
        address token
    )
        external
        view
        returns (
            address dToken,
            uint256 totalBorrows,
            uint256 totalReserves,
            uint256 reserveFactor,
            uint256 borrowIndex,
            uint256 accrualTime,
            uint256 maxDepositAmount,
            uint256 collateralWeight,
            uint256 debtWeight,
            uint256 withdrawnReserves,
            uint256 balance
        );

    /// @notice 获取 SharkDepositInfo 的详细信息
    function getSharkDepositInfo(
        address token,
        address user
    ) external view returns (address sharkToken);

    /// @notice 获取 DepositRecord 的详细信息
    function getDepositRecord(
        address token,
        address user,
        bytes32 key
    )
        external
        view
        returns (
            address dToken,
            uint256 dTokenAmount,
            uint256 amount,
            uint256 baseInterest,
            uint256 lowInterest,
            uint256 highInterest,
            uint256 lowPrice,
            uint256 highPrice,
            uint256 daysToDeposit,
            uint256 depositTimeStamp,
            uint256 depositBlock
        );

    function getIMMM() external view returns (uint256, uint256);
    function getUtilizationRate(address token) external view returns (uint256);
    function checkSafe(address pool) external view returns (bool);
    function checkCanBeLiquidated(address pool) external view returns (bool);
    function checkBorrowSafe(address pool) external view returns (bool);
    function allowedLiquidator(address liquidator) external view returns (bool);
    function getTotalDebtValue(address pool) external view returns (uint256);
    function getTotalAssetsValue(address pool) external view returns (uint256);
    function getTokenList() external view returns (address[] memory);
    function addD3PoolByFactory(address) external;

    function userDeposit(
        address user,
        address token
    ) external returns (uint256);
    function userWithdraw(
        address to,
        address user,
        address token,
        uint256 dTokenAmount
    ) external returns (uint256);

    function getExchangeRate(address token) external view returns (uint256);

    // ----------- Shark Deposit Related Functions -----------

    /// @notice 用户申购鲨鱼存款
    function buySharkDeposit(
        address user,
        address token,
        uint256 baseInterest,
        uint256 lowInterestRate,
        uint256 highInterestRate,
        uint256 lowPrice,
        uint256 highPrice,
        uint256 daysToDeposit
    ) external returns (uint256);

    /// @notice 提取用户的鲨鱼存款
    function sharkWithdraw(
        address to,
        address user,
        address token,
        uint256 dTokenAmount,
        uint256 depositTimestamp,
        uint256 depositBlock
    ) external returns (uint256);

    /// @notice 获取用户所有可提取的鲨鱼存款信息
    // function getAvailableWithdrawSharkInfo(
    //     address token,
    //     address user
    // )
    //     external
    //     view
    //     returns (
    //         uint256[] memory dTokenAmounts,
    //         uint256[] memory amounts,
    //         uint256[] memory baseInterests,
    //         uint256[] memory lowInterests,
    //         uint256[] memory highInterests,
    //         uint256[] memory lowPrices,
    //         uint256[] memory highPrices,
    //         uint256[] memory daysToDeposits,
    //         uint256[] memory depositTimeStamps,
    //         uint256[] memory depositBlocks
    //     );

    /// @notice 计算当前的鲨鱼存款收益
    function caculateCurrentSharkInterest(
        address token,
        uint256 depositBlock,
        uint256 depositTimestamp
    ) external returns (uint256);
}
