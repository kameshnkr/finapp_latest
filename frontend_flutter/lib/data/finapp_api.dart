import 'api_client.dart';
import 'models/models.dart';

class FinappApi {
  FinappApi(this._client);

  final ApiClient _client;

  Future<Map<String, dynamic>> login(String email, String otp) async {
    final j = await _client.postJson('/api/auth/login', body: {
      'email': email,
      'otp': otp,
    }) as Map<String, dynamic>;
    return j;
  }

  Future<void> logout() async {
    await _client.postEmpty('/api/auth/logout');
  }

  Future<List<AccountDto>> fetchAccounts() async {
    final j = await _client.getJson('/api/accounts/') as Map<String, dynamic>;
    final list = j['accounts'] as List<dynamic>? ?? [];
    return list.map((e) => AccountDto.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<BudgetDto>> fetchBudgets() async {
    final j = await _client.getJson('/api/budgets/') as Map<String, dynamic>;
    final list = j['budgets'] as List<dynamic>? ?? [];
    return list.map((e) => BudgetDto.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<TransactionPageDto> fetchDrafts({
    required String from,
    required String to,
    int limit = 50,
    String? cursor,
  }) async {
    final params = <String, String>{
      'from': from,
      'to': to,
      'limit': limit.toString(),
      if (cursor != null) 'cursor': cursor,
    };
    final j = await _client.getJson('/api/transactions/drafts', queryParams: params)
        as Map<String, dynamic>;
    return TransactionPageDto.fromJson(j);
  }

  Future<TransactionPageDto> fetchSettled({
    required String from,
    required String to,
    int limit = 50,
    String? cursor,
  }) async {
    final params = <String, String>{
      'from': from,
      'to': to,
      'limit': limit.toString(),
      if (cursor != null) 'cursor': cursor,
    };
    final j = await _client.getJson('/api/transactions/settled', queryParams: params)
        as Map<String, dynamic>;
    return TransactionPageDto.fromJson(j);
  }

  Future<TransactionDto> createDraft({
    required String accountId,
    required String direction,
    required String amount,
    String? note,
  }) async {
    final j = await _client.postJson('/api/transactions/drafts', body: {
      'accountId': accountId,
      'direction': direction,
      'amount': amount,
      'note': note,
    }) as Map<String, dynamic>;
    return TransactionDto.fromJson(j['transaction'] as Map<String, dynamic>);
  }

  Future<void> settle({
    required List<String> transactionIds,
    required String transactionType,
    String? budgetId,
    String? categoryId,
  }) async {
    await _client.postJson('/api/transactions/settle', body: {
      'transactionIds': transactionIds,
      'transactionType': transactionType,
      if (budgetId != null) 'budgetId': budgetId,
      if (categoryId != null) 'categoryId': categoryId,
    });
  }

  Future<TransactionDto> updateSettled(
    String id, {
    required String accountId,
    required String direction,
    required String amount,
    required String transactionType,
    required int version,
    String? budgetId,
    String? categoryId,
    String? note,
  }) async {
    final j = await _client.patchJson('/api/transactions/$id', body: {
      'accountId': accountId,
      'direction': direction,
      'amount': amount,
      'transactionType': transactionType,
      'version': version,
      'note': note,
      if (budgetId != null) 'budgetId': budgetId,
      if (categoryId != null) 'categoryId': categoryId,
    }) as Map<String, dynamic>;
    return TransactionDto.fromJson(j['transaction'] as Map<String, dynamic>);
  }

  Future<void> updateAccount(
    String id, {
    String? name,
    required String totalBalance,
    required int version,
    required List<Map<String, String>> allocations,
  }) async {
    await _client.patchJson('/api/accounts/$id', body: {
      if (name != null) 'name': name,
      'totalBalance': totalBalance,
      'version': version,
      'allocations': allocations
          .map((a) => {'budgetId': a['budgetId']!, 'amount': a['amount']!})
          .toList(),
    });
  }

  Future<void> updateBudgetMeta(
    String id, {
    required String name,
    required String resetType,
    Map<String, dynamic>? resetSchedule,
    required int version,
  }) async {
    await _client.patchJson('/api/budgets/$id', body: {
      'name': name,
      'reset_type': resetType,
      'reset_schedule': resetSchedule,
      'version': version,
    });
  }

  Future<List<BudgetDto>> upsertCategory(
    String budgetId, {
    String? categoryId,
    required String name,
    required String estimated,
    int? version,
  }) async {
    final j = await _client.postJson('/api/budgets/$budgetId/categories', body: {
      if (categoryId != null) 'id': categoryId,
      'name': name,
      'estimated': estimated,
      if (version != null) 'version': version,
    }) as Map<String, dynamic>;
    final list = j['budgets'] as List<dynamic>? ?? [];
    return list.map((e) => BudgetDto.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteCategory(String budgetId, String categoryId) async {
    await _client.deletePath(
      '/api/budgets/$budgetId/categories/$categoryId',
    );
  }

  /// Guided reallocation: move funds to/from [targetBudgetId] in one transaction.
  ///
  /// [unallocatedDeductAmount] is how much to pull from the implicit unallocated
  /// pool (empty string or "0" for decrease flows).
  /// [sources] contains the other budget allocations to reduce.
  Future<void> reallocateAllocation(
    String accountId, {
    required String targetBudgetId,
    required String targetNewAmount,
    required String unallocatedDeductAmount,
    required List<Map<String, String>> sources,
    required int version,
  }) async {
    await _client.postJson('/api/accounts/$accountId/reallocate', body: {
      'targetBudgetId': targetBudgetId,
      'targetNewAmount': targetNewAmount,
      'unallocatedDeductAmount': unallocatedDeductAmount,
      'sources': sources
          .map((s) => {
                'budgetId': s['budgetId']!,
                'deductAmount': s['deductAmount']!,
              })
          .toList(),
      'version': version,
    });
  }

  Future<void> adjustBalance(
    String accountId, {
    required String newBalance,
    required String unallocatedAmount,
    required List<Map<String, String>> distributions,
    required int version,
  }) async {
    await _client.postJson('/api/accounts/$accountId/adjustBalance', body: {
      'newBalance': newBalance,
      'unallocatedAmount': unallocatedAmount,
      'distributions': distributions
          .map((d) => {'budgetId': d['budgetId']!, 'amount': d['amount']!})
          .toList(),
      'version': version,
    });
  }

  Future<void> createAccount(String name) async {
    await _client.postJson('/api/accounts/', body: {'name': name});
  }

  Future<StatementJobDto> uploadStatement({
    required String accountId,
    required List<int> fileBytes,
    required String fileName,
    bool? isLatestStatement,
  }) async {
    final fields = <String, String>{'accountId': accountId};
    if (isLatestStatement != null) {
      fields['isLatestStatement'] = isLatestStatement.toString();
    }
    final j = await _client.postMultipartBytes(
      '/api/statements/upload',
      bytes: fileBytes,
      fileName: fileName,
      fields: fields,
    ) as Map<String, dynamic>;
    return StatementJobDto.fromUploadJson(j);
  }

  Future<StatementJobDto> getStatementStatus(String jobId) async {
    final j = await _client.getJson(
      '/api/statements/status',
      queryParams: {'job_id': jobId},
    ) as Map<String, dynamic>;
    return StatementJobDto.fromStatusJson(j);
  }

  Future<void> confirmStatement({
    required String jobId,
    required bool createDummy,
    bool createAccountBalanceDummy = false,
  }) async {
    await _client.postJson(
      '/api/statements/confirm',
      body: {
        'job_id': jobId,
        'create_dummy': createDummy,
        'create_account_balance_dummy': createAccountBalanceDummy,
      },
    );
  }

  Future<void> rejectStatement(String jobId) async {
    await _client.postJson(
      '/api/statements/reject',
      body: {'job_id': jobId},
    );
  }

  Future<void> createBudget({
    required String name,
    String resetType = 'manual',
    Map<String, dynamic>? resetSchedule,
  }) async {
    await _client.postJson('/api/budgets/', body: {
      'name': name,
      'reset_type': resetType,
      if (resetSchedule != null) 'reset_schedule': resetSchedule,
    });
  }
}
