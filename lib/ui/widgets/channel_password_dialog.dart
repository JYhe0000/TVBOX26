import 'package:flutter/material.dart';

import '../../theme/ui.dart';
import 'common.dart';

Future<bool> unlockChannel(BuildContext context, String password) async {
  if (password.isEmpty) return true;
  var input = '';
  var failed = false;
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) {
            final skin = TvSkin.of(context);
            final text = AppText.of(context);
            return Dialog(
              backgroundColor: Colors.transparent,
              child: SizedBox(
                width: 420,
                child: SkinSurface(
                  enableBlur: false,
                  padding: EdgeInsets.all(skin.spaceLg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('频道密码', style: text.section),
                      SizedBox(height: skin.spaceMd),
                      Text(
                        failed
                            ? '密码错误，请重新输入'
                            : (input.isEmpty ? '请输入数字密码' : '●' * input.length),
                        style: text.bodyStrong,
                      ),
                      SizedBox(height: skin.spaceMd),
                      Wrap(
                        spacing: skin.spaceSm,
                        runSpacing: skin.spaceSm,
                        children: [
                          for (final digit in [
                            '1',
                            '2',
                            '3',
                            '4',
                            '5',
                            '6',
                            '7',
                            '8',
                            '9',
                            '删除',
                            '0',
                            '解锁',
                          ])
                            TvFocusable(
                              autofocus: digit == '1',
                              semanticLabel: digit,
                              onTap: () {
                                if (digit == '解锁') {
                                  if (input == password) {
                                    Navigator.pop(context, true);
                                  } else {
                                    update(() {
                                      failed = true;
                                      input = '';
                                    });
                                  }
                                } else {
                                  update(() {
                                    failed = false;
                                    if (digit == '删除') {
                                      if (input.isNotEmpty) {
                                        input = input.substring(
                                          0,
                                          input.length - 1,
                                        );
                                      }
                                    } else if (input.length < 16) {
                                      input += digit;
                                    }
                                  });
                                }
                              },
                              child: SizedBox(
                                width: 100,
                                height: 48,
                                child: Center(
                                  child: Text(digit, style: text.bodyStrong),
                                ),
                              ),
                            ),
                        ],
                      ),
                      SizedBox(height: skin.spaceMd),
                      TvFocusable(
                        semanticLabel: '取消',
                        onTap: () => Navigator.pop(context, false),
                        child: Padding(
                          padding: EdgeInsets.all(skin.spaceSm),
                          child: Text('取消', style: text.body),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ) ??
      false;
}
