import 'package:flutter_bloc/flutter_bloc.dart';

abstract class CommsEvent {}
abstract class CommsState {}

class CommsInitial extends CommsState {}

/// BLoC handling Lane 2: Zero-latency P2P walkie-talkie link handling WebRTC logic
class CommsBloc extends Bloc<CommsEvent, CommsState> {
  CommsBloc() : super(CommsInitial()) {
    on<CommsEvent>((event, emit) {
      // Event handling logic
    });
  }
}
