import 'package:flutter_test/flutter_test.dart';
import 'package:app/features/music/data/datasources/subsonic_api_client.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

void main() {
  late SubsonicApiClient apiClient;
  late MockDio mockDio;

  setUp(() {
    mockDio = MockDio();
    apiClient = SubsonicApiClient(
      baseUrl: 'http://localhost:4533',
      username: 'test_user',
      password: 'test_password',
      dio: mockDio,
    );
  });

  group('SubsonicApiClient', () {
    test('authQuery generates required Subsonic auth format', () {
      final query = apiClient.authQuery;
      expect(query.contains('u=test_user'), isTrue);
      expect(query.contains('t='), isTrue); // token
      expect(query.contains('s='), isTrue); // salt
      expect(query.contains('v=1.16.1'), isTrue);
      expect(query.contains('c=nakama'), isTrue);
      expect(query.contains('f=json'), isTrue);
    });

    test('getPlaylists successfully parses valid mock JSON response', () async {
      final mockResponse = {
        'subsonic-response': {
          'status': 'ok',
          'playlists': {
            'playlist': [
              {'id': '1', 'name': 'Gym Tunes', 'songCount': 10, 'duration': 3000}
            ]
          }
        }
      };

      when(() => mockDio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((_) async => Response(
                data: mockResponse,
                statusCode: 200,
                requestOptions: RequestOptions(path: ''),
              ));

      final playlists = await apiClient.getPlaylists();
      
      expect(playlists.length, 1);
      expect(playlists.first['id'], '1');
      expect(playlists.first['name'], 'Gym Tunes');
    });

    test('getPlaylists throws Exception on "failed" status', () async {
      final mockResponse = {
        'subsonic-response': {
          'status': 'failed',
          'error': {'message': 'Invalid token'}
        }
      };

      when(() => mockDio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((_) async => Response(
                data: mockResponse,
                statusCode: 200,
                requestOptions: RequestOptions(path: ''),
              ));

      expect(() => apiClient.getPlaylists(), throwsA(isA<Exception>()));
    });
  });
}
