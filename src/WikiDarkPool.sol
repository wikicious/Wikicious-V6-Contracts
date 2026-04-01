// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiDarkPool
 * @notice Private order matching for large trades. Commit-reveal scheme
 *         prevents front-running. Institutions pay 0.15% fee vs 0.07% standard.
 *
 * HOW IT WORKS (commit-reveal):
 *   Phase 1 — COMMIT (block N):
 *     Trader submits: keccak256(abi.encodePacked(isBuy, price, amount, salt))
 *     No one can see the actual order details
 *
 *   Phase 2 — REVEAL (block N+1 to N+10):
 *     Trader reveals: isBuy, price, amount, salt
 *     Contract verifies hash matches commitment
 *     Order enters the dark pool matching queue
 *
 *   Phase 3 — MATCH (keeper, every block):
 *     Keeper calls matchOrders() to find crossing buy/sell pairs
 *     Matched at midpoint price — both sides win vs market price
 *     Unmatched orders expire after maxBlocks
 *
 * WHO USES IT:
 *   Whales: $500K+ positions that would move the market on-chain
 *   Market makers: proprietary inventory management
 *   Institutions: OTC-equivalent execution on-chain
 *
 * FEE STRUCTURE:
 *   Dark pool fee: 0.15% of notional (vs 0.07% standard)
 *   Maker rebate:  0.02% of notional (incentivises liquidity)
 *   Net taker fee: 0.13%
 *   Net protocol:  0.15% - 0.02% = 0.13% blended
 */
contract WikiDarkPool is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    struct Commitment {
        address trader;
        bytes32 hash;
        uint256 commitBlock;
        bool    revealed;
        bool    expired;
    }

    struct DarkOrder {
        address trader;
        uint256 marketId;
        bool    isBuy;
        uint256 price;        // limit price (8 dec)
        uint256 amount;       // USDC notional (6 dec)
        uint256 revealBlock;
        uint256 expireBlock;
        bool    filled;
        bool    cancelled;
    }

    mapping(bytes32 => Commitment) public commitments;   // commitHash → commitment
    mapping(uint256 => DarkOrder)  public darkOrders;    // orderId → order
    mapping(uint256 => uint256[])  public marketBuys;    // marketId → buy orderIds
    mapping(uint256 => uint256[])  public marketSells;   // marketId → sell orderIds
    mapping(address => uint256[])  public userOrders;

    address public revenueSplitter;
    address public keeper;

    uint256 public nextOrderId;
    uint256 public darkPoolFeeBps   = 15;  // 0.15%
    uint256 public makerRebateBps   = 2;   // 0.02%
    uint256 public revealWindow     = 10;  // blocks to reveal after commit
    uint256 public orderExpiry      = 50;  // blocks until unmatched order expires
    uint256 public minOrderUsdc     = 50_000 * 1e6; // $50K minimum order
    uint256 public constant BPS     = 10_000;

    event CommitSubmitted(bytes32 indexed commitHash, address trader, uint256 block_);
    event OrderRevealed(uint256 orderId, address trader, uint256 marketId, bool isBuy, uint256 price, uint256 amount);
    event OrderMatched(uint256 buyOrderId, uint256 sellOrderId, uint256 matchPrice, uint256 matchAmount);
    event OrderExpired(uint256 orderId);

    constructor(address _owner, address _usdc, address _revenueSplitter, address _keeper) Ownable(_owner) {
        USDC             = IERC20(_usdc);
        revenueSplitter  = _revenueSplitter;
        keeper           = _keeper;
    }

    // ── Phase 1: Commit ───────────────────────────────────────────────────
    /**
     * @notice Submit order commitment. No one can see your order details yet.
     * @param commitHash keccak256(abi.encodePacked(marketId, isBuy, price, amount, salt))
     */
    function commit(bytes32 commitHash) external {
        require(commitments[commitHash].trader == address(0), "DP: commitment exists");
        commitments[commitHash] = Commitment({
            trader:      msg.sender,
            hash:        commitHash,
            commitBlock: block.number,
            revealed:    false,
            expired:     false
        });
        emit CommitSubmitted(commitHash, msg.sender, block.number);
    }

    // ── Phase 2: Reveal ───────────────────────────────────────────────────
    /**
     * @notice Reveal your order. Verifies against commitment hash.
     *         Must be called within revealWindow blocks of commit.
     */
    function reveal(
        uint256 marketId,
        bool    isBuy,
        uint256 price,
        uint256 amount,
        bytes32 salt
    ) external nonReentrant returns (uint256 orderId) {
        bytes32 commitHash = keccak256(abi.encodePacked(marketId, isBuy, price, amount, salt));
        Commitment storage c = commitments[commitHash];

        require(c.trader == msg.sender,                                "DP: not your commitment");
        require(!c.revealed,                                           "DP: already revealed");
        require(block.number <= c.commitBlock + revealWindow,          "DP: reveal window closed");
        require(amount >= minOrderUsdc,                                "DP: below minimum order size");

        c.revealed = true;

        // Collect margin
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        orderId = nextOrderId++;
        darkOrders[orderId] = DarkOrder({
            trader:      msg.sender,
            marketId:    marketId,
            isBuy:       isBuy,
            price:       price,
            amount:      amount,
            revealBlock: block.number,
            expireBlock: block.number + orderExpiry,
            filled:      false,
            cancelled:   false
        });

        if (isBuy)  marketBuys[marketId].push(orderId);
        else        marketSells[marketId].push(orderId);
        userOrders[msg.sender].push(orderId);

        emit OrderRevealed(orderId, msg.sender, marketId, isBuy, price, amount);
    }

    // ── Phase 3: Match (keeper) ───────────────────────────────────────────
    /**
     * @notice Match crossing buy/sell orders at midpoint price.
     *         Keeper scans revealed orders and finds pairs where buy.price >= sell.price.
     */
    function matchOrders(uint256 marketId, uint256 buyId, uint256 sellId) external nonReentrant {
        require(msg.sender == keeper || msg.sender == owner(), "DP: not keeper");

        DarkOrder storage buy  = darkOrders[buyId];
        DarkOrder storage sell = darkOrders[sellId];

        require(!buy.filled  && !buy.cancelled  && block.number <= buy.expireBlock,  "DP: buy invalid");
        require(!sell.filled && !sell.cancelled && block.number <= sell.expireBlock, "DP: sell invalid");
        require(buy.marketId == marketId && sell.marketId == marketId, "DP: market mismatch");
        require(buy.isBuy && !sell.isBuy,  "DP: not crossing orders");
        require(buy.price >= sell.price,   "DP: prices don't cross");

        // Match at midpoint
        uint256 matchPrice  = (buy.price + sell.price) / 2;
        uint256 matchAmount = buy.amount < sell.amount ? buy.amount : sell.amount;

        // Fee calculation
        uint256 takerFee    = matchAmount * darkPoolFeeBps / BPS;
        uint256 makerRebate = matchAmount * makerRebateBps / BPS;
        uint256 protocolFee = takerFee - makerRebate;

        // Buyer (taker) pays fee
        uint256 buyerReturn = matchAmount - takerFee;
        // Seller (maker) gets rebate
        uint256 sellerReturn= matchAmount + makerRebate;

        buy.filled  = true;
        sell.filled = true;

        // Distribute
        USDC.safeTransfer(buy.trader,  buyerReturn);
        USDC.safeTransfer(sell.trader, sellerReturn);
        if (protocolFee > 0) USDC.safeTransfer(revenueSplitter, protocolFee);

        emit OrderMatched(buyId, sellId, matchPrice, matchAmount);
    }

    // ── Cancel / Expire ───────────────────────────────────────────────────
    function cancelOrder(uint256 orderId) external nonReentrant {
        DarkOrder storage o = darkOrders[orderId];
        require(o.trader == msg.sender, "DP: not your order");
        require(!o.filled && !o.cancelled, "DP: already final");
        o.cancelled = true;
        USDC.safeTransfer(msg.sender, o.amount);
    }

    function expireOrder(uint256 orderId) external nonReentrant {
        DarkOrder storage o = darkOrders[orderId];
        require(!o.filled && !o.cancelled, "DP: already final");
        require(block.number > o.expireBlock, "DP: not expired");
        o.cancelled = true;
        USDC.safeTransfer(o.trader, o.amount);
        emit OrderExpired(orderId);
    }

    // ── Views ──────────────────────────────────────────────────────────────
    function getOrder(uint256 id) external view returns (DarkOrder memory) { return darkOrders[id]; }
    function getUserOrders(address user) external view returns (uint256[] memory) { return userOrders[user]; }

    function getActiveOrderCount(uint256 marketId) external view returns (uint256 buys, uint256 sells) {
        uint256[] storage b = marketBuys[marketId];
        uint256[] storage s = marketSells[marketId];
        for (uint i; i < b.length; i++) if (!darkOrders[b[i]].filled && !darkOrders[b[i]].cancelled && block.number <= darkOrders[b[i]].expireBlock) buys++;
        for (uint i; i < s.length; i++) if (!darkOrders[s[i]].filled && !darkOrders[s[i]].cancelled && block.number <= darkOrders[s[i]].expireBlock) sells++;
    }

    // ── Admin ──────────────────────────────────────────────────────────────
    function setFees(uint256 feeBps, uint256 rebateBps) external onlyOwner {
        require(feeBps <= 30 && rebateBps < feeBps, "DP: fee bounds");
        darkPoolFeeBps = feeBps; makerRebateBps = rebateBps;
    }
    function setMinOrder(uint256 min) external onlyOwner { minOrderUsdc = min; }
    function setKeeper(address k)    external onlyOwner { keeper = k; }
}
