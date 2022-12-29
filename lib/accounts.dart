import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/data_fb_generated.dart' ;
import 'package:warp_api/types.dart';
import 'coin/coins.dart';
import 'package:mobx/mobx.dart';
import 'db.dart';
import 'package:warp_api/warp_api.dart';

import 'backup.dart';
import 'coin/coin.dart';
import 'coin/zcash.dart';
import 'main.dart';
import 'store.dart';

part 'accounts.g.dart';

class Account {
  final int coin;
  final int id;
  final String name;
  final int balance;
  int tbalance = 0;

  Account(this.coin, this.id, this.name, this.balance, this.tbalance);

  String get address {
    return id != 0 ? WarpApi.getAddress(this.coin, this.id, settings.uaType) : "";
  }
}

final Account emptyAccount = Account(0, 0, "", 0, 0);

class AccountList {
  List<Account> list = [];

  AccountList() {
    refresh();
  }

  void refresh() {
    List<Account> _list = [];
    for (var coin in coins) {
      _list.addAll(WarpApi.getAccountList(coin.coin).map((a) => Account(
        coin.coin, a.id, a.name!, a.balance, 0)
      ));
    }
    list = _list;
  }

  bool get isEmpty { return list.isEmpty; }

  Future<void> updateTBalance() async {
    for (var a in list) {
      final tbalance = await WarpApi.getTBalanceAsync(a.coin, a.id);
      a.tbalance = tbalance;
    }
  }

  Future<void> delete(int coin, int id) async {
    WarpApi.deleteAccount(coin, id);
    await active.checkAndUpdate();
  }

  Future<void> changeAccountName(int coin, int id, String name) async {
    WarpApi.updateAccountName(coin, id, name);
    refresh();
  }

  void saveActive(int coin, int id) {
    settings.coins[coin].active = id;
    Future.microtask(() async {
      final prefs = await SharedPreferences.getInstance();
      final def = settings.coins[coin].def;
      prefs.setInt("${def.ticker}.active", id);
    });
  }

  Account get(int coin, int id) => list.firstWhere((e) => e.coin == coin && e.id == id, orElse: () => emptyAccount);
}

class ActiveAccount = _ActiveAccount with _$ActiveAccount;

abstract class _ActiveAccount with Store {
  @observable int dataEpoch = 0;

  @observable int coin = 0;
  @observable int id = 0;

  Account account = emptyAccount;
  CoinBase coinDef = zcash;
  bool canPay = false;
  Balances balances = Balances();
  @observable String taddress = "";
  int tbalance = 0;
  PoolBalances poolBalances = PoolBalances();

  @observable List<Note> notes = [];
  @observable List<Tx> txs = [];
  @observable List<Spending> spendings = [];
  @observable List<TimeSeriesPoint<double>> accountBalances = [];
  @observable List<PnL> pnls = [];
  @observable ObservableList<ZMessage> messages = ObservableList();
  @observable int unread = 0;
  @observable String banner = "";

  @observable
  bool showTAddr = false;

  @observable
  SortConfig noteSortConfig = SortConfig("", SortOrder.Unsorted);

  @observable
  SortConfig txSortConfig = SortConfig("", SortOrder.Unsorted);

  @observable
  int pnlSeriesIndex = 0;

  @observable
  bool pnlDesc = false;

  @observable
  Recipient? draftRecipient = null;

  AccountId toId() { return AccountId(coin, id); }

  @action
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final coin = prefs.getInt('coin') ?? 0;
    var id = prefs.getInt('account') ?? 0;
    await setActiveAccount(coin, id);
    await checkAndUpdate();
    await refreshAccount();
  }

  Future<void> checkAndUpdate() async {
    final aid = await getAvailableId(active.toId());
    if (aid == null) {
      await setActiveAccount(0, 0);
    }
    else if (aid != active.toId()) {
      await setActiveAccount(aid.coin, aid.id);
      await refreshAccount();
    }
  }

  Future<AccountId?> getAvailableId(AccountId aid) async {
    final nid = getAvailableIdForCoin(aid.coin, aid.id);
    if (nid.id != 0) return nid;
    for (var coin_data in settings.coins) {
      // look for an account in any other coin
      if (coin_data.coin != coin) {
        final nid = getAvailableIdForCoin(coin_data.coin, coin_data.active);
        if (nid.id != 0)
          return nid;
      }
    }
    // We have no accounts
    return null;
  }

  // check that the account still exists
  // if not, pick any account
  // if there are none, return 0
  AccountId getAvailableIdForCoin(int coin, int id) {
    final newId = WarpApi.getAvailableAccountId(coin, id);
    return AccountId(coin, newId);
  }

  @action
  Future<void> setActiveAccount(int _coin, int _id) async {
    coin = _coin;
    id = _id;

    final prefs = await SharedPreferences.getInstance();
    prefs.setInt('coin', coin);
    prefs.setInt('account', id);
    WarpApi.setActiveAccount(coin, id);
  }

  @action
  Future<void> refreshAccount() async {
    final dbr = DbReader(coin, id);
    coinDef = settings.coins[coin].def;

    final accounts = AccountList();
    accounts.refresh();
    account = accounts.get(coin, id);

    if (id > 0) {
      taddress = WarpApi.getTAddr(coin, id);
      canPay = WarpApi.getSK(coin, id).isNotEmpty;
    }

    showTAddr = false;
    balances.initialized = false;
    draftRecipient = null;

    await update();
    Future.microtask(priceStore.updateChart);
  }

  @action
  Future<void> refreshTAddr() async {
    taddress = WarpApi.getTAddr(coin, id);
  }

  @action
  void toggleShowTAddr() {
    showTAddr = !showTAddr;
  }

  @action
  void updateTBalance() {
    try {
      tbalance = WarpApi.getTBalance();
    }
    on String {}
  }

  @action
  void updateBalances() {
    final dbr = DbReader(coin, id);
    final initialized = balances.initialized;
    final prevBalance = balances.balance;
    final b = WarpApi.getBalance(coin, id, syncStatus.confirmHeight);
    balances.update(b.balance, b.shielded, b.unconfirmedSpent, b.underConfirmed, b.excluded);
    if (initialized && prevBalance != balances.balance) {
      showBalanceNotification(prevBalance, balances.balance);
    }
  }

  @action
  void clear() {
    messages.clear();
    notes.clear();
    txs.clear();
    unread = 0;
    dataEpoch += 1;
  }

  @action
  Future<void> update() async {
    updateBalances();
    updateTBalance();
    poolBalances.update();

    final dbr = DbReader(coin, id);
    notes = dbr.getNotes();
    txs = dbr.getTxs();
    messages = ObservableList.of(await dbr.getMessages());
    unread = messages.where((m) => !m.read).length;
    dataEpoch += 1;
  }

  @action
  void setDraftRecipient(Recipient? v) {
    draftRecipient = v;
  }

  String newAddress() {
    return WarpApi.newDiversifiedAddress(settings.uaType);
  }

  String getAddress(int uaType) {
    return WarpApi.getAddress(coin, id, uaType);
  }

  @computed
  List<Note> get sortedNotes {
    final _1 = syncStatus.syncedHeight;
    var notes2 = [...notes];
    switch (noteSortConfig.field) {
      case "time":
        return _sort(notes2, (Note note) => note.height, noteSortConfig.order);
      case "amount":
        return _sort(notes2, (Note note) => note.value, noteSortConfig.order);
    }
    return notes2;
  }

  @computed
  List<Tx> get sortedTxs {
    final _1 = syncStatus.syncedHeight;
    var txs2 = [...txs];
    switch (txSortConfig.field) {
      case "time":
        return _sort(txs2, (Tx tx) => tx.height, txSortConfig.order);
      case "amount":
        return _sort(txs2, (Tx tx) => tx.value, txSortConfig.order);
      case "txid":
        return _sort(txs2, (Tx tx) => tx.txid, txSortConfig.order);
      case "address":
        return _sort(
            txs2, (Tx tx) => tx.contact ?? tx.address, txSortConfig.order);
      case "memo":
        return _sort(txs2, (Tx tx) => tx.memo, txSortConfig.order);
    }
    return txs2;
  }

  @action
  void sortNotes(String field) {
    noteSortConfig = noteSortConfig.sortOn(field);
  }

  @action
  void sortTx(String field) {
    txSortConfig = txSortConfig.sortOn(field);
  }

  List<C> _sort<C extends HasHeight, T extends Comparable>(
      List<C> items, T Function(C) project, SortOrder order) {
    switch (order) {
      case SortOrder.Ascending:
        items.sort((a, b) => project(a).compareTo(project(b)));
        break;
      case SortOrder.Descending:
        items.sort((a, b) => -project(a).compareTo(project(b)));
        break;
      case SortOrder.Unsorted:
        items.sort((a, b) => -a.height.compareTo(b.height));
        break;
    }
    return items;
  }

  @action
  void setPnlSeriesIndex(int index) {
    pnlSeriesIndex = index;
  }

  @computed
  List<PnL> get pnlSorted {
    if (pnlDesc) {
      var _pnls = [...pnls.reversed];
      return _pnls;
    }
    return pnls;
  }

  @action
  void togglePnlDesc() {
    pnlDesc = !pnlDesc;
  }

  @action
  void excludeNote(Note note) {
    WarpApi.updateExcluded(coin, note.id, note.excluded);
  }

  @action
  void invertExcludedNotes() {
    WarpApi.invertExcluded(coin, id);
    notes = notes.map((n) => n.invertExcluded).toList();
  }

  @action
  void fetchChartData() {
    final dbr = active.dbReader;
    pnls = dbr.getPNL(active.id);
    spendings = dbr.getSpending(active.id);
    accountBalances = dbr.getAccountBalanceTimeSeries(active.id, active.balances?.balance ?? 0);
  }

  @action
  void markMessageAsRead(int index) {
    if (!messages[index].read) {
      WarpApi.markMessageAsRead(messages[index].id, true);
      messages[index] = messages[index].withRead(true);
      unread = unread - 1;
    }
  }

  @action
  void markAllMessagesAsRead() {
    WarpApi.markAllMessagesAsRead(true);
    for (var i = 0; i < messages.length; i++) {
      messages[i] = messages[i].withRead(true);
    }
    unread = 0;
  }

  int prevInThread(int index) {
    final message = messages[index];
    final pn = WarpApi.getPrevNextMessage(coin, id, message.subject, message.height);
    return pn.prev;
  }

  int nextInThread(int index) {
    final message = messages[index];
    final pn = WarpApi.getPrevNextMessage(coin, id, message.subject, message.height);
    return pn.next;
  }

  @action
  void setBanner(String msg) {
    banner = msg;
  }

  String get address {
    return account.address;
  }

  DbReader get dbReader => DbReader(coin, id);
}

class Balances = _Balances with _$Balances;

abstract class _Balances with Store {
  bool initialized = false;
  @observable int balance = 0;
  @observable int shieldedBalance = 0;
  @observable int unconfirmedSpentBalance = 0;
  @observable int underConfirmedBalance = 0;
  @observable int excludedBalance = 0;

  @action
  void update(int balance, int shieldedBalance, int unconfirmedSpentBalance, int underConfirmedBalance, int excludedBalance) {
    this.balance = balance;
    this.shieldedBalance = shieldedBalance;
    this.unconfirmedSpentBalance = unconfirmedSpentBalance;
    this.underConfirmedBalance = underConfirmedBalance;
    this.excludedBalance = excludedBalance;
    this.initialized = true;
  }
}

class AccountId {
  final int coin;
  final int id;
  AccountId(this.coin, this.id);
}

class PoolBalances = _PoolBalances with _$PoolBalances;

abstract class _PoolBalances with Store {
  @observable int transparent = 0;
  @observable int sapling = 0;
  @observable int orchard = 0;

  void update() {
    final b = WarpApi.getBalance(active.coin, active.id, syncStatus.confirmHeight);
    _update(active.tbalance, b.sapling, b.orchard);
  }

  @action
  _update(int t, int s, int o) {
    transparent = t;
    sapling = s;
    orchard = o;
  }
}
