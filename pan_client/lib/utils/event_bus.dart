import 'dart:async';

class EventBus {
  static final EventBus _instance = EventBus._internal();
  factory EventBus() => _instance;
  EventBus._internal();

  final _streamController = StreamController<String>.broadcast();

  Stream<String> get stream => _streamController.stream;

  void emit(String event) {
    _streamController.add(event);
  }
}

final globalEventBus = EventBus();