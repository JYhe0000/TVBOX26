class LivePreferences {
  const LivePreferences({
    this.timeoutSeconds = 12,
    this.reverse = false,
    this.crossGroup = false,
    this.showClock = true,
    this.showNetwork = false,
  });
  final int timeoutSeconds;
  final bool reverse;
  final bool crossGroup;
  final bool showClock;
  final bool showNetwork;

  factory LivePreferences.fromJson(Map json) => LivePreferences(
    timeoutSeconds: [8, 12, 20, 30].contains(json['timeout'])
        ? json['timeout'] as int
        : 12,
    reverse: json['reverse'] == true,
    crossGroup: json['crossGroup'] == true,
    showClock: json['showClock'] != false,
    showNetwork: json['showNetwork'] == true,
  );
  Map<String, dynamic> toJson() => {
    'timeout': timeoutSeconds,
    'reverse': reverse,
    'crossGroup': crossGroup,
    'showClock': showClock,
    'showNetwork': showNetwork,
  };
  LivePreferences copyWith({
    int? timeoutSeconds,
    bool? reverse,
    bool? crossGroup,
    bool? showClock,
    bool? showNetwork,
  }) => LivePreferences(
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    reverse: reverse ?? this.reverse,
    crossGroup: crossGroup ?? this.crossGroup,
    showClock: showClock ?? this.showClock,
    showNetwork: showNetwork ?? this.showNetwork,
  );
}
