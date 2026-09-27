// Investments DTOs — independent of Banking's models.dart. Field names
// mirror the backend's investments_* API responses exactly (see
// backend/src/services/investmentsPortfolioService.ts).

class InvestmentsPotDto {
  InvestmentsPotDto({
    required this.id,
    required this.name,
    required this.description,
    required this.currentValue,
  });

  final String id;
  final String name;
  final String? description;
  final String currentValue;

  factory InvestmentsPotDto.fromJson(Map<String, dynamic> j) => InvestmentsPotDto(
        id: j['id'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        currentValue: j['currentValue'] as String,
      );
}

/// Response of GET /api/investments/pots/ — Total Portfolio Value + all
/// active Pots with their current derived value.
class InvestmentsPortfolioDto {
  InvestmentsPortfolioDto({
    required this.totalPortfolioValue,
    required this.pots,
  });

  final String totalPortfolioValue;
  final List<InvestmentsPotDto> pots;

  factory InvestmentsPortfolioDto.fromJson(Map<String, dynamic> j) {
    final list = (j['pots'] as List<dynamic>? ?? [])
        .map((e) => InvestmentsPotDto.fromJson(e as Map<String, dynamic>))
        .toList();
    return InvestmentsPortfolioDto(
      totalPortfolioValue: j['totalPortfolioValue'] as String,
      pots: list,
    );
  }
}

/// One row of GET /api/investments/accounts/ — plain Account identity,
/// including [version] (needed for the optimistic-concurrency rename call).
class InvestmentsAccountDto {
  InvestmentsAccountDto({
    required this.id,
    required this.name,
    required this.brokerName,
    required this.accountIdentifier,
    required this.status,
    required this.version,
  });

  final String id;
  final String name;
  final String? brokerName;
  final String? accountIdentifier;
  final String status;
  final int version;

  factory InvestmentsAccountDto.fromJson(Map<String, dynamic> j) => InvestmentsAccountDto(
        id: j['id'] as String,
        name: j['name'] as String,
        brokerName: j['brokerName'] as String?,
        accountIdentifier: j['accountIdentifier'] as String?,
        status: j['status'] as String,
        version: j['version'] as int,
      );
}

/// A single Pot's read-only allocation breakdown for one Asset — always
/// includes every active Pot, even ones with zero allocation (per spec).
class InvestmentsPotAllocationDto {
  InvestmentsPotAllocationDto({
    required this.potId,
    required this.potName,
    required this.percentage,
    required this.amount,
  });

  final String potId;
  final String potName;
  final String percentage;
  final String amount;

  factory InvestmentsPotAllocationDto.fromJson(Map<String, dynamic> j) => InvestmentsPotAllocationDto(
        potId: j['potId'] as String,
        potName: j['potName'] as String,
        percentage: j['percentage'] as String,
        amount: j['amount'] as String,
      );
}

class InvestmentsAssetDto {
  InvestmentsAssetDto({
    required this.accountAssetId,
    required this.assetId,
    required this.isin,
    required this.name,
    required this.symbol,
    required this.assetClass,
    required this.units,
    required this.latestPrice,
    required this.priceDate,
    required this.currentValue,
    required this.potAllocations,
  });

  final String accountAssetId;
  final String assetId;
  final String isin;
  final String name;
  final String? symbol;
  final String assetClass;
  final String units;
  final String? latestPrice;
  final String? priceDate;
  final String currentValue;
  final List<InvestmentsPotAllocationDto> potAllocations;

  factory InvestmentsAssetDto.fromJson(Map<String, dynamic> j) {
    final allocs = (j['potAllocations'] as List<dynamic>? ?? [])
        .map((e) => InvestmentsPotAllocationDto.fromJson(e as Map<String, dynamic>))
        .toList();
    return InvestmentsAssetDto(
      accountAssetId: j['accountAssetId'] as String,
      assetId: j['assetId'] as String,
      isin: j['isin'] as String,
      name: j['name'] as String,
      symbol: j['symbol'] as String?,
      assetClass: j['assetClass'] as String,
      units: j['units'] as String,
      latestPrice: j['latestPrice'] as String?,
      priceDate: j['priceDate'] as String?,
      currentValue: j['currentValue'] as String,
      potAllocations: allocs,
    );
  }
}

/// One row of GET /api/investments/assets/ — an Investment Account with its
/// Assets grouped underneath (Account is a visual grouping only, never
/// collapsible — see AssetsTab spec).
class InvestmentsAccountAssetsDto {
  InvestmentsAccountAssetsDto({
    required this.accountId,
    required this.accountName,
    required this.brokerName,
    required this.accountIdentifier,
    required this.assets,
  });

  final String accountId;
  final String accountName;
  final String? brokerName;
  final String? accountIdentifier;
  final List<InvestmentsAssetDto> assets;

  factory InvestmentsAccountAssetsDto.fromJson(Map<String, dynamic> j) {
    final assets = (j['assets'] as List<dynamic>? ?? [])
        .map((e) => InvestmentsAssetDto.fromJson(e as Map<String, dynamic>))
        .toList();
    return InvestmentsAccountAssetsDto(
      accountId: j['accountId'] as String,
      accountName: j['accountName'] as String,
      brokerName: j['brokerName'] as String?,
      accountIdentifier: j['accountIdentifier'] as String?,
      assets: assets,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Trades — Unlabeled/Labeled lists (GET .../trades/unlabeled|labeled) and the
// Allocate endpoint (POST .../trades/allocate). Field names mirror
// investmentsTradeQueryService.ts's serializeTrade()/serializeBreakdown()
// exactly.
// ══════════════════════════════════════════════════════════════════════════

/// One (Pot, Trade) allocation row — only ever present on an ALLOCATED
/// trade's [InvestmentsTradeDto.potAllocations]. `allocatedAmount` isn't
/// returned by the backend (only units are persisted); it's derived
/// client-side as `allocatedUnits * trade.price`, matching the spec's
/// "Allocated Amount (Derived value at runtime)".
class InvestmentsTradeAllocationDto {
  InvestmentsTradeAllocationDto({
    required this.potId,
    required this.potName,
    required this.percentage,
    required this.allocatedUnits,
  });

  final String potId;
  final String potName;
  final String percentage;
  final String allocatedUnits;

  factory InvestmentsTradeAllocationDto.fromJson(Map<String, dynamic> j) => InvestmentsTradeAllocationDto(
        potId: j['potId'] as String,
        potName: j['potName'] as String,
        percentage: j['percentage'] as String,
        allocatedUnits: j['allocatedUnits'] as String,
      );
}

class InvestmentsTradeDto {
  InvestmentsTradeDto({
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.accountAssetId,
    required this.isin,
    required this.assetName,
    required this.symbol,
    required this.assetClass,
    required this.transactionType,
    required this.units,
    required this.price,
    required this.amount,
    required this.transactionDate,
    required this.allocationStatus,
    required this.potAllocations,
    required this.version,
  });

  final String id;
  final String accountId;
  final String accountName;
  final String accountAssetId;
  final String isin;
  final String assetName;
  final String? symbol;
  final String assetClass;
  final String transactionType; // BUY | SELL
  final String units;
  final String price;
  final String amount;
  final String transactionDate; // yyyy-MM-dd
  final String allocationStatus; // UNALLOCATED | ALLOCATED
  final List<InvestmentsTradeAllocationDto> potAllocations;
  final int version;

  bool get isBuy => transactionType == 'BUY';

  factory InvestmentsTradeDto.fromJson(Map<String, dynamic> j) {
    final allocs = (j['potAllocations'] as List<dynamic>? ?? [])
        .map((e) => InvestmentsTradeAllocationDto.fromJson(e as Map<String, dynamic>))
        .toList();
    return InvestmentsTradeDto(
      id: j['id'] as String,
      accountId: j['accountId'] as String,
      accountName: j['accountName'] as String,
      accountAssetId: j['accountAssetId'] as String,
      isin: j['isin'] as String,
      assetName: j['assetName'] as String,
      symbol: j['symbol'] as String?,
      assetClass: j['assetClass'] as String,
      transactionType: j['transactionType'] as String,
      units: j['units'] as String,
      price: j['price'] as String,
      amount: j['amount'] as String,
      transactionDate: j['transactionDate'] as String,
      allocationStatus: j['allocationStatus'] as String,
      potAllocations: allocs,
      version: j['version'] as int,
    );
  }
}

class InvestmentsTradesPageDto {
  InvestmentsTradesPageDto({
    required this.trades,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<InvestmentsTradeDto> trades;
  final String? nextCursor;
  final bool hasMore;

  factory InvestmentsTradesPageDto.fromJson(Map<String, dynamic> j) {
    final trades = (j['trades'] as List<dynamic>? ?? [])
        .map((e) => InvestmentsTradeDto.fromJson(e as Map<String, dynamic>))
        .toList();
    return InvestmentsTradesPageDto(
      trades: trades,
      nextCursor: j['nextCursor'] as String?,
      hasMore: j['hasMore'] as bool? ?? false,
    );
  }
}

/// Response of POST /api/investments/prices/refresh — mirrors
/// PriceRefreshResult in investmentsPriceRefreshService.ts exactly.
class InvestmentsPriceRefreshResultDto {
  InvestmentsPriceRefreshResultDto({
    required this.eligibleCount,
    required this.updatedCount,
    required this.notFoundIsins,
    required this.alreadyCurrentCount,
  });

  final int eligibleCount;
  final int updatedCount;
  final List<String> notFoundIsins;
  final int alreadyCurrentCount;

  factory InvestmentsPriceRefreshResultDto.fromJson(Map<String, dynamic> j) =>
      InvestmentsPriceRefreshResultDto(
        eligibleCount: (j['eligibleCount'] as num?)?.toInt() ?? 0,
        updatedCount: (j['updatedCount'] as num?)?.toInt() ?? 0,
        notFoundIsins: (j['notFoundIsins'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
        alreadyCurrentCount: (j['alreadyCurrentCount'] as num?)?.toInt() ?? 0,
      );
}

// ══════════════════════════════════════════════════════════════════════════
// Add Trade upload — job status polling + reconciliation confirmation.
// Field names mirror investmentsUploadProcessingService.ts /
// investmentsReconciliationService.ts exactly.
// ══════════════════════════════════════════════════════════════════════════

/// One per-asset unit mismatch found during reconciliation (Holdings file
/// units vs. existing + new trades). The user must resolve every mismatch
/// (create the proposed dummy trade, or skip it) before confirming.
class InvestmentsReconciliationMismatchDto {
  InvestmentsReconciliationMismatchDto({
    required this.accountAssetId,
    required this.isin,
    required this.assetName,
    required this.existingUnits,
    required this.buyUnits,
    required this.sellUnits,
    required this.expectedUnits,
    required this.holdingsUnits,
    required this.dummyType,
    required this.dummyUnits,
    required this.dummyPrice,
    required this.canCreateDummy,
  });

  final String accountAssetId;
  final String isin;
  final String assetName;
  final String existingUnits;
  final String buyUnits;
  final String sellUnits;
  final String expectedUnits;
  final String holdingsUnits;
  final String dummyType; // BUY | SELL
  final String dummyUnits;
  final String? dummyPrice;
  final bool canCreateDummy;

  factory InvestmentsReconciliationMismatchDto.fromJson(Map<String, dynamic> j) =>
      InvestmentsReconciliationMismatchDto(
        accountAssetId: j['accountAssetId'] as String,
        isin: j['isin'] as String,
        assetName: j['assetName'] as String,
        existingUnits: j['existingUnits'] as String,
        buyUnits: j['buyUnits'] as String,
        sellUnits: j['sellUnits'] as String,
        expectedUnits: j['expectedUnits'] as String,
        holdingsUnits: j['holdingsUnits'] as String,
        dummyType: j['dummyType'] as String,
        dummyUnits: j['dummyUnits'] as String,
        dummyPrice: j['dummyPrice'] as String?,
        canCreateDummy: j['canCreateDummy'] as bool,
      );
}

class InvestmentsUploadConfirmationDataDto {
  InvestmentsUploadConfirmationDataDto({
    required this.mismatches,
    required this.totalExtracted,
    required this.duplicatesSkipped,
    required this.pendingCount,
  });

  final List<InvestmentsReconciliationMismatchDto> mismatches;
  final int totalExtracted;
  final int duplicatesSkipped;
  final int pendingCount;

  factory InvestmentsUploadConfirmationDataDto.fromJson(Map<String, dynamic> j) {
    final mismatches = (j['mismatches'] as List<dynamic>? ?? [])
        .map((e) => InvestmentsReconciliationMismatchDto.fromJson(e as Map<String, dynamic>))
        .toList();
    return InvestmentsUploadConfirmationDataDto(
      mismatches: mismatches,
      totalExtracted: (j['totalExtracted'] as num?)?.toInt() ?? 0,
      duplicatesSkipped: (j['duplicatesSkipped'] as num?)?.toInt() ?? 0,
      pendingCount: (j['pendingCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// COMPLETED job result — note the backend persists this as raw JSONB with
/// **snake_case** keys (investmentsUploadJobRepository.completeJob stores
/// exactly what's passed in), unlike every other Investments response.
class InvestmentsUploadResultDto {
  InvestmentsUploadResultDto({
    required this.totalExtracted,
    required this.totalInserted,
    required this.duplicatesSkipped,
    required this.reconciledCount,
  });

  final int totalExtracted;
  final int totalInserted;
  final int duplicatesSkipped;
  final int reconciledCount;

  factory InvestmentsUploadResultDto.fromJson(Map<String, dynamic> j) => InvestmentsUploadResultDto(
        totalExtracted: (j['total_extracted'] as num?)?.toInt() ?? 0,
        totalInserted: (j['total_inserted'] as num?)?.toInt() ?? 0,
        duplicatesSkipped: (j['duplicates_skipped'] as num?)?.toInt() ?? 0,
        reconciledCount: (j['reconciled_count'] as num?)?.toInt() ?? 0,
      );
}

class InvestmentsUploadJobStatusDto {
  InvestmentsUploadJobStatusDto({
    required this.status,
    this.message,
    this.errorMessage,
    this.confirmationData,
    this.result,
  });

  final String status;
  final String? message;
  final String? errorMessage;
  final InvestmentsUploadConfirmationDataDto? confirmationData;
  final InvestmentsUploadResultDto? result;

  factory InvestmentsUploadJobStatusDto.fromJson(Map<String, dynamic> j) {
    final status = j['status'] as String;
    return InvestmentsUploadJobStatusDto(
      status: status,
      message: j['message'] as String?,
      errorMessage: j['errorMessage'] as String?,
      confirmationData: j['confirmationData'] != null
          ? InvestmentsUploadConfirmationDataDto.fromJson(j['confirmationData'] as Map<String, dynamic>)
          : null,
      result: j['result'] != null
          ? InvestmentsUploadResultDto.fromJson(j['result'] as Map<String, dynamic>)
          : null,
    );
  }
}
