import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/models.dart';

List<String> names(List<Episode> episodes) =>
    episodes.map((episode) => episode.name).toList();

List<Episode> episodes(List<String> values) => [
  for (var i = 0; i < values.length; i++)
    Episode(name: values[i], url: 'https://a.test/$i.m3u8', index: i),
];

void main() {
  group('parseEpisodeNumber', () {
    test('常见集名都能解析出集数', () {
      expect(parseEpisodeNumber('第12集'), 12);
      expect(parseEpisodeNumber('第01集'), 1);
      expect(parseEpisodeNumber('第十二集'), 12);
      expect(parseEpisodeNumber('第百零一集'), 101);
      expect(parseEpisodeNumber('EP12'), 12);
      expect(parseEpisodeNumber('S01E02'), 2);
      expect(parseEpisodeNumber('12'), 12);
      expect(parseEpisodeNumber('第2集 高清'), 2);
      expect(parseEpisodeNumber('预告'), isNull);
      expect(parseEpisodeNumber('花絮'), isNull);
    });
  });

  group('normalizeEpisodeOrder', () {
    test('倒序源自动翻正（第3集 → 第1集）', () {
      final result = normalizeEpisodeOrder(
        episodes(['第3集', '第2集', '第1集']),
      );
      expect(names(result), ['第1集', '第2集', '第3集']);
      expect(result.map((episode) => episode.index), [0, 1, 2]);
    });

    test('两集倒序也会翻正', () {
      final result = normalizeEpisodeOrder(episodes(['第2集', '第1集']));
      expect(names(result), ['第1集', '第2集']);
    });

    test('升序源保持不变', () {
      final input = episodes(['第1集', '第2集', '第3集']);
      final result = normalizeEpisodeOrder(input);
      expect(names(result), ['第1集', '第2集', '第3集']);
      expect(result.first.url, input.first.url);
    });

    test('中文集数与 EP 命名同样翻正', () {
      expect(
        names(normalizeEpisodeOrder(episodes(['第十二集', '第十一集', '第十集']))),
        ['第十集', '第十一集', '第十二集'],
      );
      expect(
        names(normalizeEpisodeOrder(episodes(['EP3', 'EP2', 'EP1']))),
        ['EP1', 'EP2', 'EP3'],
      );
    });

    test('乱序、重复、纯非集名都保持原样', () {
      final mixed = episodes(['第1集', '第3集', '第2集']);
      expect(names(normalizeEpisodeOrder(mixed)), ['第1集', '第3集', '第2集']);

      final duplicated = episodes(['第1集', '第1集', '第2集']);
      expect(
        names(normalizeEpisodeOrder(duplicated)),
        ['第1集', '第1集', '第2集'],
      );

      final extras = episodes(['预告', '花絮', '正片']);
      expect(names(normalizeEpisodeOrder(extras)), ['预告', '花絮', '正片']);
    });

    test('parseEpisodes 直接返回翻正后的顺序', () {
      final parsed = VodItem.parseEpisodes(
        r'第2集$https://a.test/2.m3u8#第1集$https://a.test/1.m3u8',
      );
      expect(names(parsed), ['第1集', '第2集']);
      expect(parsed.first.url, 'https://a.test/1.m3u8');
    });
  });
}