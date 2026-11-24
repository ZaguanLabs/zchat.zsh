"""Local protocol fixture; no external credentials or services."""
import json
import gzip
import sys
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def responses_events():
    """Responses lifecycle shapes from the official streaming reference.

    Exercise metadata between deltas, reasoning summaries, output items, and
    the nested final Response rather than a two-event approximation.
    """
    usage = dict(input_tokens=9, output_tokens=2, total_tokens=11,
                 input_tokens_details=dict(cached_tokens=0),
                 output_tokens_details=dict(reasoning_tokens=1))
    text = dict(type='output_text', text='fixture reply 🌍', annotations=[], logprobs=[])
    message = dict(id='msg_fixture', type='message', role='assistant',
                   status='completed', content=[text])
    reasoning = dict(id='rs_fixture', type='reasoning',
                     summary=[dict(type='summary_text', text='fixture thought')])
    response = dict(id='resp_fixture', object='response', created_at=1741476542,
                    status='completed', error=None, incomplete_details=None,
                    output=[reasoning, message], usage=usage, model='another-model', store=False)
    return [
        dict(type='response.created', response={**response, 'status': 'in_progress', 'output': [], 'usage': None}),
        dict(type='response.in_progress', response={**response, 'status': 'in_progress', 'output': [], 'usage': None}),
        dict(type='response.reasoning_summary_text.delta', item_id='rs_fixture', output_index=0,
             summary_index=0, delta='fixture thought'),
        dict(type='response.output_item.added', output_index=1,
             item={**message, 'status': 'in_progress', 'content': []}),
        dict(type='response.content_part.added', item_id='msg_fixture', output_index=1,
             content_index=0, part={**text, 'text': ''}),
        dict(type='response.output_text.delta', item_id='msg_fixture', output_index=1,
             content_index=0, delta='fixture reply 🌍', logprobs=[], obfuscation='abc123'),
        dict(type='response.output_text.done', item_id='msg_fixture', output_index=1,
             content_index=0, text='fixture reply 🌍', logprobs=[]),
        dict(type='response.content_part.done', item_id='msg_fixture', output_index=1,
             content_index=0, part=text),
        dict(type='response.output_item.done', output_index=1, item=message),
        dict(type='response.completed', response=response),
    ]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert body['stream'] is True
        assert 'options' not in body
        if self.path == '/responses-json-error':
            wire = json.dumps(dict(error=dict(message="Unknown model", type="invalid_request_error",
                                              code="model_not_found", param="model"))).encode()
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(wire)))
            self.end_headers()
            self.wfile.write(wire)
            return
        if self.path == '/http-error':
            self.send_error(401)
            return
        if self.path in ('/truncated', '/malformed', '/slow', '/redirect', '/api-error'):
            if self.path == '/redirect':
                self.send_response(307)
                self.send_header('Location', '/chat/completions')
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            if self.path == '/malformed':
                self.wfile.write(b'data: {broken}\n\n')
            elif self.path == '/api-error':
                self.wfile.write(b'data: {"error":{"message":"fixture overloaded"}}\n\n')
            else:
                self.wfile.write(b'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n')
                self.wfile.flush()
                if self.path == '/slow':
                    time.sleep(10)
            return
        if self.path == '/chat/completions':
            assert body['messages'][0]['role'] == 'system'
            events = [dict(choices=[dict(delta=dict(content='fixture reply 🌍'))]),
                      dict(choices=[], usage=dict(prompt_tokens=9, completion_tokens=2)), '[DONE]']
        elif self.path.startswith('/responses'):
            assert body['instructions']
            assert body['input'][0]['role'] == 'user'
            assert body['input'][1]['role'] == 'assistant'
            assert isinstance(body['input'][0]['content'], str)
            assert isinstance(body['input'][1]['content'], str)
            assert body['max_output_tokens'] > 0
            assert not {'messages', 'max_tokens', 'max_completion_tokens', 'temperature'} & body.keys()
            events = responses_events()
            if self.path == '/responses-done':
                events.append('[DONE]')
            elif self.path == '/responses-early-done':
                events = ['[DONE]']
            elif self.path == '/responses-truncated':
                events = events[:-1]
            elif self.path == '/responses-sse-error':
                events = [dict(type='error', code='invalid_request', param='input', message='Bad input')]
            elif self.path == '/responses-failed':
                events[-1] = dict(type='response.failed', response=dict(status='failed',
                                  error=dict(code='server_error', message='Upstream failed')))
            elif self.path == '/responses-incomplete':
                events[-1] = dict(type='response.incomplete', response=dict(status='incomplete',
                                  incomplete_details=dict(reason='max_output_tokens'),
                                  usage=dict(input_tokens=9, output_tokens=2)))
            elif self.path == '/responses-bad-completed':
                events[-1] = dict(type='response.completed')
        elif self.path == '/messages':
            assert self.headers['x-api-key'] == 'secret for fixture'
            assert self.headers['anthropic-version'] == '2023-06-01'
            assert body['system']
            assert body['max_tokens'] > 0
            events = [dict(type='message_start', message=dict(usage=dict(input_tokens=9, output_tokens=1))),
                      dict(type='content_block_delta', delta=dict(type='text_delta', text='fixture reply 🌍')),
                      dict(type='message_delta', usage=dict(output_tokens=2)), dict(type='message_stop')]
        else:
            self.send_error(404)
            return
        lines = []
        for sequence, event in enumerate(events):
            if isinstance(event, str):
                lines.append('data: ' + event + '\r\n\r\n')
            else:
                if self.path.startswith('/responses'):
                    event['sequence_number'] = sequence
                    lines.append('event: ' + event['type'] + '\r\n')
                lines.append('data: ' + json.dumps(event, ensure_ascii=False) + '\r\n\r\n')
        wire = ''.join(lines).encode()
        if self.path == '/responses-gzip':
            assert 'gzip' in self.headers.get('Accept-Encoding', '')
            wire = gzip.compress(wire)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(wire)))
        if self.path == '/responses-gzip':
            self.send_header('Content-Encoding', 'gzip')
        self.end_headers()
        for i in range(0, len(wire), 7):
            self.wfile.write(wire[i:i + 7])
            self.wfile.flush()
            time.sleep(.001)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
if len(sys.argv) == 4:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[2], sys.argv[3])
    server.socket = context.wrap_socket(server.socket, server_side=True)
with open(sys.argv[1], 'w') as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
