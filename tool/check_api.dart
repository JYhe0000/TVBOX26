// ignore_for_file: avoid_print
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';

Future<void> main() async {
  final api = SiteApi();
  const site = SiteConfig(
    key: 'bdzy',
    name: '百度资源',
    api: 'https://api.apibdzy.com/api.php/provide/vod/',
    type: 1,
  );
  final home = await api.home(site);
  print(
    'home: ${home.videos.length} videos, ${home.categories.length} categories, pageCount=${home.pageCount}',
  );
  print(
    'first: ${home.videos.first.name} (${home.videos.first.id}) ${home.videos.first.typeName}',
  );
  final catalog = await api.category(site, home.categories.first.id, 1);
  print(
    'category ${home.categories.first.name}: ${catalog.videos.length} videos',
  );
  final search = await api.search(site, '火影');
  print('search: ${search.length} videos');
  final detail = await api.detail(site, home.videos.first.id);
  print('detail: ${detail.name}, lines=${detail.lines.length}');
  if (detail.lines.isNotEmpty) {
    print(
      'line0=${detail.lines.first.name}, episodes=${detail.lines.first.episodes.length}',
    );
    print(
      'ep0=${detail.lines.first.episodes.first.name} ${detail.lines.first.episodes.first.url}',
    );
  }
}
