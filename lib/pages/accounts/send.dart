import 'package:YWallet/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp/data_fb_generated.dart';
import 'package:warp/warp.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../generated/intl/messages.dart';
import '../input_widgets.dart';
import '../utils.dart';

class SendPage extends StatefulWidget {
  final bool single;
  final PaymentRequestT? payment;

  SendPage(this.payment, {this.single = true});

  @override
  State<StatefulWidget> createState() => SendPageState();
}

class SendPageState extends State<SendPage> {
  late final S s = S.of(context);
  final formKey = GlobalKey<FormBuilderState>();
  final amountKey = GlobalKey<AmountPickerState>();
  int toRecvAvailable = 0;
  late final BalanceT balance;
  late String fromAddress;
  late int fromRecvAvailable;

  bool custom = appSettings.customSend;

  late String address;
  int? fromRecvSelected;
  int? toRecvSelected;
  late int amount;
  late bool feeIncluded;
  late UserMemoT memo;

  @override
  void initState() {
    super.initState();

    final recipient = widget.payment?.recipients?.firstOrNull;
    print(recipient);
    address = recipient?.address ?? '';
    amount = recipient?.amount ?? 0;
    memo = recipient?.memo ?? UserMemoT(subject: '', body: '');
    if (warp.isValidAddressOrUri(aa.coin, address) == 1)
      toRecvAvailable = warp.decodeAddress(aa.coin, address).mask;
    feeIncluded = widget.payment?.senderPayFees ?? true;

    balance =
        warp.getBalance(aa.coin, aa.id, syncStatus.confirmHeight ?? MAXHEIGHT);
    fromAddress = warp.getAccountAddress(aa.coin, aa.id, now(), 7);
    fromRecvAvailable = warp.decodeAddress(aa.coin, fromAddress).mask;
  }

  @override
  Widget build(BuildContext context) {
    final css = appSettings.customSendSettings;
    final extraAddressButtons = [
      if (custom && css.accounts) AddressBookButton,
      if (custom && css.contacts) AccountsBookButton,
    ];
    final isShielded = (toRecvSelected ?? toRecvAvailable) & 6 != 0;

    return Scaffold(
      appBar: AppBar(title: Text(s.send), actions: [
        IconButton(
            onPressed: () => setState(() => custom = !custom),
            icon: Icon(Icons.tune)),
        IconButton(onPressed: send, icon: Icon(Icons.send)),
      ]),
      body: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, 0),
          child: FormBuilder(
            key: formKey,
            child: Column(
              children: [
                TextQRPicker(address,
                    name: 'address',
                    label: Text(s.address),
                    extraButtons: extraAddressButtons,
                    validator: addressValidator,
                    onChanged: onAddressChanged,
                    onSaved: (v) => v?.let((v) => address = v)),
                Gap(8),
                SegmentedPicker(toRecvAvailable,
                    key: ValueKey(toRecvAvailable),
                    name: 'to_receivers',
                    available: toRecvAvailable,
                    labels: [
                      Text(s.transparent, style: TextStyle(color: Colors.red)),
                      Text(s.sapling, style: TextStyle(color: Colors.orange)),
                      Text(s.orchard, style: TextStyle(color: Colors.green))
                    ],
                    onSaved: (v) => toRecvSelected = v,
                    multiSelectionEnabled: true,
                    show: toRecvAvailable != 0 && custom && css.recipientPools),
                Gap(8),
                SegmentedPicker(fromRecvAvailable,
                    name: 'from_receivers',
                    available: fromRecvAvailable,
                    labels: [
                      Text(amountToString(balance.transparent),
                          style: TextStyle(color: Colors.green)),
                      Text(amountToString(balance.sapling),
                          style: TextStyle(color: Colors.orange)),
                      Text(amountToString(balance.orchard),
                          style: TextStyle(color: Colors.red))
                    ],
                    onSaved: (v) => fromRecvSelected = v,
                    multiSelectionEnabled: true,
                    show: custom && css.pools),
                Gap(8),
                AmountPicker(
                  amount,
                  key: amountKey,
                  name: 'amount',
                  showSlider: custom && css.amountSlider,
                  showFiat: custom && css.amountCurrency,
                  maxAmount: balance.total,
                  onSaved: (v) => v?.let((v) => amount = v),
                ),
                Gap(8),
                Row(children: [
                  Expanded(
                      child: (custom && css.deductFee)
                          ? FormBuilderSwitch(
                              name: 'fee_included',
                              title: Text(s.deductFee),
                              initialValue: !feeIncluded,
                              onSaved: (v) => v?.let((v) => feeIncluded = !v),
                            )
                          : SizedBox.shrink()),
                  if (custom && css.max)
                    IconButton(
                        onPressed: maximize,
                        icon: FaIcon(FontAwesomeIcons.maximize))
                ]),
                Gap(8),
                MemoInput(memo,
                    name: 'memo',
                    show: isShielded && (!custom || css.memo),
                    advanced: custom && css.memoSubject),
                Gap(8),
                Divider(),
                Gap(8),
                IconButton(onPressed: send, icon: Icon(Icons.send)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  onAddressChanged(String? address) {
    if (address == null) return;
    if (warp.isValidAddressOrUri(aa.coin, address) == 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final p = warp.parsePaymentURI(aa.coin, address, syncStatus.syncedHeight, syncStatus.expirationHeight);
        GoRouter.of(context).go('/account/send', extra: p);
      });
    }
    setState(() {
      toRecvAvailable = 0;
      if (warp.isValidAddressOrUri(aa.coin, address) == 1)
        toRecvAvailable = warp.decodeAddress(aa.coin, address).mask;
    });
  }

  maximize() {
    setState(() {
      feeIncluded = true;
      formKey.currentState!.fields['fee_included']?.setValue(true);
      amountKey.currentState!.maximize();
    });
  }

  send() {
    formKey.currentState!.saveAndValidate();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      print(address);
      print(fromRecvSelected ?? fromRecvAvailable);
      print(toRecvSelected ?? toRecvAvailable);
      print(amount);
      print(feeIncluded);
      print(memo);
      if (formKey.currentState!.isValid) {
        final height = syncStatus.latestHeight ?? syncStatus.syncedHeight;
        final recipient = RecipientT(
            address: address,
            amount: amount,
            pools: toRecvSelected ?? toRecvAvailable,
            memo: memo);
        final payment = PaymentRequestT(
            recipients: [recipient],
            srcPools: fromRecvSelected ?? fromRecvAvailable,
            senderPayFees: feeIncluded,
            useChange: true,
            height: height,
            expiration: height + 50);
        final tx = await warp.pay(aa.coin, aa.id, payment);
        GoRouter.of(context).push('/account/txplan?tab=account', extra: tx);
      }
    });
  }
}

Widget AddressBookButton(
  BuildContext context,
  String? Function(String?)? validator,
  FormFieldState<String> field,
  QRValueSetter setter,
) {
  return IconButton(
    onPressed: () async {
      final cc = await GoRouter.of(context)
          .push<ContactCardT>('/account/send/contacts');
      cc?.address?.let((a) => setter(field, a));
    },
    icon: FaIcon(FontAwesomeIcons.addressBook),
  );
}

Widget AccountsBookButton(
  BuildContext context,
  String? Function(String?)? validator,
  FormFieldState<String> field,
  QRValueSetter setter,
) {
  return IconButton(
    onPressed: () async {
      final account = await GoRouter.of(context)
          .push<AccountNameT>('/account/send/accounts');
      if (account != null) {
        final address = warp.getAccountAddress(aa.coin, account.id, now(), 7);
        setter(field, address);
      }
    },
    icon: FaIcon(FontAwesomeIcons.users),
  );
}
