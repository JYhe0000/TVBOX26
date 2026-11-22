// ignore_for_file: avoid_print
import 'package:tvbox_flutter/data/live_parser.dart';
import 'package:tvbox_flutter/data/models.dart';

Future<void> main() async {
  final service = LiveService();
  final result = await service.load(
    const LiveSource(
      name: '国内 IPTV 合集',
      url: 'https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u',
    ),
  );
  print(
    'groups=${result.groups.length}, channels=${result.channelCount}, warning=${result.warning}',
  );
  for (final group in result.groups.take(5)) {
    print('${group.name}: ${group.channels.length}');
  }
}
