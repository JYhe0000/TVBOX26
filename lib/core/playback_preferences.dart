enum PlaybackScale {
  original('原始比例'),
  wide('16:9'),
  classic('4:3'),
  cover('裁剪铺满'),
  stretch('拉伸铺满');

  const PlaybackScale(this.label);
  final String label;

  static PlaybackScale fromName(String name) =>
      values.firstWhere((value) => value.name == name, orElse: () => original);
}

const playbackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];
