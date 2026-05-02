class UserDto {
  UserDto({required this.id, required this.email});
  final String id;
  final String email;

  factory UserDto.fromJson(Map<String, dynamic> j) =>
      UserDto(id: j['id'] as String, email: j['email'] as String);
}

class AccountDto {
  AccountDto({
    required this.id,
    required this.name,
    required this.totalBalance,
    required this.version,
    this.allocations = const [],
  });

  final String id;
  final String name;
  final String totalBalance;
  final int version;
  final List<AllocationDto> allocations;

  factory AccountDto.fromJson(Map<String, dynamic> j) {
    final allocs = (j['allocations'] as List<dynamic>? ?? [])
        .map((e) => AllocationDto.fromJson(e as Map<String, dynamic>))
        .toList();
    return AccountDto(
      id: j['id'] as String,
      name: j['name'] as String,
      totalBalance: j['totalBalance'] as String,
      version: j['version'] as int,
      allocations: allocs,
    );
  }
}

class AllocationDto {
  AllocationDto({
    required this.budgetId,
    required this.budgetName,
    required this.amount,
  });

  final String budgetId;
  final String budgetName;
  final String amount;

  factory AllocationDto.fromJson(Map<String, dynamic> j) => AllocationDto(
        budgetId: j['budgetId'] as String,
        budgetName: j['budgetName'] as String,
        amount: j['amount'] as String,
      );
}

class CategoryDto {
  CategoryDto({
    required this.id,
    required this.name,
    required this.estimated,
    required this.spent,
    required this.remaining,
    required this.version,
  });

  final String id;
  final String name;
  final String estimated;
  final String spent;
  final String remaining;
  final int version;

  factory CategoryDto.fromJson(Map<String, dynamic> j) => CategoryDto(
        id: j['id'] as String,
        name: j['name'] as String,
        estimated: j['estimated'] as String,
        spent: j['spent'] as String,
        remaining: j['remaining'] as String,
        version: j['version'] as int,
      );
}

class BudgetDto {
  BudgetDto({
    required this.id,
    required this.name,
    required this.resetType,
    this.resetSchedule,
    this.periodStart,
    this.periodEnd,
    required this.estimated,
    required this.spent,
    required this.fundsAvailable,
    required this.allocationCount,
    required this.version,
    required this.categories,
  });

  final String id;
  final String name;
  /// 'manual' | 'scheduled'
  final String resetType;
  /// Non-null for scheduled budgets: { type, date, is_last_day_of_month }
  final Map<String, dynamic>? resetSchedule;
  final String? periodStart;
  final String? periodEnd;
  final String estimated;
  final String spent;
  final String fundsAvailable;
  /// Number of accounts that have allocations to this budget
  final int allocationCount;
  final int version;
  final List<CategoryDto> categories;

  factory BudgetDto.fromJson(Map<String, dynamic> j) {
    final cats = (j['categories'] as List<dynamic>? ?? [])
        .map((e) => CategoryDto.fromJson(e as Map<String, dynamic>))
        .toList();
    return BudgetDto(
      id: j['id'] as String,
      name: j['name'] as String,
      resetType: j['resetType'] as String? ?? 'manual',
      resetSchedule: j['resetSchedule'] as Map<String, dynamic>?,
      periodStart: j['periodStart'] as String?,
      periodEnd: j['periodEnd'] as String?,
      estimated: j['estimated'] as String,
      spent: j['spent'] as String,
      fundsAvailable: j['fundsAvailable'] as String,
      allocationCount: j['allocationCount'] as int? ?? 0,
      version: j['version'] as int,
      categories: cats,
    );
  }
}

class TransactionDto {
  TransactionDto({
    required this.id,
    required this.accountId,
    required this.direction,
    required this.amount,
    required this.status,
    required this.version,
    this.budgetId,
    this.categoryId,
    this.transactionType,
    this.description,
    this.descriptionReadable,
    this.note,
    this.settledAt,
    this.transactionDate,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String accountId;
  final String? budgetId;
  final String? categoryId;
  final String direction;
  final String amount;
  final String status;
  final String? transactionType;
  /// Raw bank statement description (as printed in statement)
  final String? description;
  /// Human-friendly label extracted by LLM (e.g. "Meridian Restaurant")
  final String? descriptionReadable;
  final String? note;
  final String? settledAt;
  /// YYYY-MM-DD actual date from bank statement; null for manual transactions
  final String? transactionDate;
  final int version;
  final String createdAt;
  final String updatedAt;

  factory TransactionDto.fromJson(Map<String, dynamic> j) => TransactionDto(
        id: j['id'] as String,
        accountId: j['accountId'] as String,
        budgetId: j['budgetId'] as String?,
        categoryId: j['categoryId'] as String?,
        direction: j['direction'] as String,
        amount: j['amount'] as String,
        status: j['status'] as String,
        transactionType: j['transactionType'] as String?,
        description: j['description'] as String?,
        descriptionReadable: j['descriptionReadable'] as String?,
        note: j['note'] as String?,
        settledAt: j['settledAt'] as String?,
        transactionDate: j['transactionDate'] as String?,
        version: j['version'] as int,
        createdAt: j['createdAt'] as String,
        updatedAt: j['updatedAt'] as String,
      );
}

class BudgetSnapshotDto {
  BudgetSnapshotDto({
    required this.id,
    required this.estimated,
    required this.spent,
    required this.fundsAvailable,
    this.periodStart,
    this.periodEnd,
  });

  final String id;
  final String estimated;
  final String spent;
  final String fundsAvailable;
  final String? periodStart;
  final String? periodEnd;

  factory BudgetSnapshotDto.fromJson(Map<String, dynamic> j) =>
      BudgetSnapshotDto(
        id: j['id'] as String,
        estimated: j['estimated'] as String,
        spent: j['spent'] as String,
        fundsAvailable: j['fundsAvailable'] as String,
        periodStart: j['periodStart'] as String?,
        periodEnd: j['periodEnd'] as String?,
      );
}

class StatementJobDto {
  StatementJobDto({
    required this.jobId,
    required this.status,
    this.message,
    this.result,
    this.errorMessage,
    this.confirmationData,
  });

  final String jobId;

  /// UPLOADING | PROCESSING | VALIDATING | SAVING | COMPLETED | FAILED
  /// | AWAITING_CONFIRMATION | REJECTED
  final String status;

  /// Progress message for in-progress states
  final String? message;

  /// Present when status == COMPLETED
  final StatementJobResultDto? result;

  /// Present when status == FAILED
  final String? errorMessage;

  /// Present when status == AWAITING_CONFIRMATION
  final StatementConfirmationDataDto? confirmationData;

  factory StatementJobDto.fromUploadJson(Map<String, dynamic> j) =>
      StatementJobDto(
        jobId: j['job_id'] as String,
        status: j['status'] as String,
      );

  factory StatementJobDto.fromStatusJson(Map<String, dynamic> j) {
    final resultMap = j['result'] as Map<String, dynamic>?;
    final confirmMap = j['confirmation_data'] as Map<String, dynamic>?;
    return StatementJobDto(
      jobId: '',
      status: j['status'] as String,
      message: j['message'] as String?,
      errorMessage: j['error_message'] as String?,
      result:
          resultMap != null ? StatementJobResultDto.fromJson(resultMap) : null,
      confirmationData: confirmMap != null
          ? StatementConfirmationDataDto.fromJson(confirmMap)
          : null,
    );
  }
}

/// Data returned when the job is in AWAITING_CONFIRMATION state.
class StatementConfirmationDataDto {
  StatementConfirmationDataDto({
    required this.delta,
    required this.allowedDelta,
    required this.deltaStatus,
    required this.dummyType,
    required this.latestDate,
    required this.totalExtracted,
    required this.duplicatesSkipped,
    required this.pendingCount,
    this.acctDelta,
    this.acctDummyType,
    this.acctDbBalance,
    this.acctProjectedBalance,
    this.acctClosingBalance,
  });

  /// Absolute internal balance gap (₹) — from opening/closing check
  final double delta;

  /// Maximum allowed gap before it becomes an ERROR
  final double allowedDelta;

  /// 'OK', 'WARNING' or 'ERROR'
  final String deltaStatus;

  /// Direction of internal dummy transaction: 'CREDIT' or 'DEBIT'
  final String dummyType;

  /// Latest transaction date in the statement (YYYY-MM-DD)
  final String latestDate;

  final int totalExtracted;
  final int duplicatesSkipped;

  /// How many non-duplicate transactions are pending insertion
  final int pendingCount;

  // ── Account balance reconciliation fields ──────────────────────────────────

  /// Absolute account balance gap (₹); null = check was not triggered or passed
  final double? acctDelta;

  /// Direction of account balance reconciliation dummy: 'CREDIT' or 'DEBIT'
  final String? acctDummyType;

  /// Account total_balance from DB at time of processing
  final double? acctDbBalance;

  /// Projected balance after settling all statement drafts + new items
  final double? acctProjectedBalance;

  /// Statement closing balance used for the account check
  final double? acctClosingBalance;

  factory StatementConfirmationDataDto.fromJson(Map<String, dynamic> j) =>
      StatementConfirmationDataDto(
        delta: (j['delta'] as num).toDouble(),
        allowedDelta: (j['allowed_delta'] as num).toDouble(),
        deltaStatus: j['delta_status'] as String,
        dummyType: j['dummy_type'] as String? ?? 'DEBIT',
        latestDate: j['latest_date'] as String? ?? '',
        totalExtracted: (j['total_extracted'] as num).toInt(),
        duplicatesSkipped: (j['duplicates_skipped'] as num).toInt(),
        pendingCount: (j['pending_count'] as num).toInt(),
        acctDelta: j['acct_delta'] != null ? (j['acct_delta'] as num).toDouble() : null,
        acctDummyType: j['acct_dummy_type'] as String?,
        acctDbBalance: j['acct_db_balance'] != null ? (j['acct_db_balance'] as num).toDouble() : null,
        acctProjectedBalance: j['acct_projected_balance'] != null ? (j['acct_projected_balance'] as num).toDouble() : null,
        acctClosingBalance: j['acct_closing_balance'] != null ? (j['acct_closing_balance'] as num).toDouble() : null,
      );
}

class StatementJobResultDto {
  StatementJobResultDto({
    required this.totalExtracted,
    required this.totalInserted,
    required this.duplicatesSkipped,
    required this.validationStatus,
    this.dummyInserted = false,
    this.acctDummyInserted = false,
  });

  final int totalExtracted;
  final int totalInserted;
  final int duplicatesSkipped;

  /// 'SUCCESS' | 'REVIEW_REQUIRED'
  final String validationStatus;

  /// Whether an internal balance adjustment dummy was inserted
  final bool dummyInserted;

  /// Whether an account balance reconciliation dummy was inserted
  final bool acctDummyInserted;

  factory StatementJobResultDto.fromJson(Map<String, dynamic> j) =>
      StatementJobResultDto(
        totalExtracted: (j['total_extracted'] as num).toInt(),
        totalInserted: (j['total_inserted'] as num).toInt(),
        duplicatesSkipped: (j['duplicates_skipped'] as num).toInt(),
        validationStatus: j['validation_status'] as String? ?? 'SUCCESS',
        dummyInserted: j['dummy_inserted'] as bool? ?? false,
        acctDummyInserted: j['acct_dummy_inserted'] as bool? ?? false,
      );
}

class TransactionPageDto {
  TransactionPageDto({
    required this.transactions,
    required this.hasMore,
    this.nextCursor,
  });

  final List<TransactionDto> transactions;
  final bool hasMore;
  final String? nextCursor;

  factory TransactionPageDto.fromJson(Map<String, dynamic> j) {
    final list = (j['transactions'] as List<dynamic>? ?? [])
        .map((e) => TransactionDto.fromJson(e as Map<String, dynamic>))
        .toList();
    return TransactionPageDto(
      transactions: list,
      hasMore: j['hasMore'] as bool? ?? false,
      nextCursor: j['nextCursor'] as String?,
    );
  }
}
