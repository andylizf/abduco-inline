static void client_sigwinch_handler(int sig) {
	client.need_resize = true;
}

static bool client_send_packet(Packet *pkt) {
	print_packet("client-send:", pkt);
	if (send_packet(server.socket, pkt))
		return true;
	debug("FAILED\n");
	server.running = false;
	return false;
}

static bool client_recv_packet(Packet *pkt) {
	if (recv_packet(server.socket, pkt)) {
		print_packet("client-recv:", pkt);
		return true;
	}
	debug("client-recv: FAILED\n");
	server.running = false;
	return false;
}

static bool client_expect_pid(void) {
	Packet pkt;
	return client_recv_packet(&pkt) && pkt.type == MSG_PID;
}

static bool buffer_append(char **buf, size_t *len, size_t *cap, const char *data, size_t data_len) {
	if (data_len > SIZE_MAX - *len)
		return false;
	size_t need = *len + data_len;
	if (need > *cap) {
		size_t new_cap = *cap ? *cap : 4096;
		while (new_cap < need) {
			if (new_cap > SIZE_MAX / 2)
				return false;
			new_cap *= 2;
		}
		char *new_buf = realloc(*buf, new_cap);
		if (!new_buf)
			return false;
		*buf = new_buf;
		*cap = new_cap;
	}
	memcpy(*buf + *len, data, data_len);
	*len += data_len;
	return true;
}

static size_t tail_line_start(const char *buf, size_t len, size_t lines) {
	if (!lines || !len)
		return 0;

	size_t pos = len;
	if (pos > 0 && buf[pos - 1] == '\n')
		pos--;

	size_t found = 0;
	while (pos > 0) {
		pos--;
		if (buf[pos] == '\n') {
			found++;
			if (found == lines)
				return pos + 1;
		}
	}
	return 0;
}

static bool dump_session(const char *name, size_t max_bytes, size_t max_lines) {
	char *buf = NULL;
	size_t len = 0, cap = 0;

	if (server.socket > 0)
		close(server.socket);
	if ((server.socket = session_connect(name)) == -1)
		goto error;
	if (!client_expect_pid())
		goto error;

	Packet pkt = { .type = MSG_DUMP };
	if (!client_send_packet(&pkt))
		goto error;

	while (client_recv_packet(&pkt)) {
		switch (pkt.type) {
		case MSG_CONTENT:
			if (!buffer_append(&buf, &len, &cap, pkt.u.msg, pkt.len))
				goto error;
			break;
		case MSG_DUMP_END:
		{
			size_t start = 0;
			if (max_bytes && max_bytes < len)
				start = len - max_bytes;
			if (max_lines) {
				size_t line_start = tail_line_start(buf + start, len - start, max_lines);
				start += line_start;
			}
			if (write_all(STDOUT_FILENO, buf + start, len - start) != len - start)
				goto error;
			free(buf);
			close(server.socket);
			server.socket = -1;
			return true;
		}
		default:
			break;
		}
	}

error:
	free(buf);
	if (server.socket > 0) {
		close(server.socket);
		server.socket = -1;
	}
	return false;
}

static bool send_bytes(const char *bytes, size_t len) {
	while (len > 0) {
		Packet pkt = { .type = MSG_SEND_KEYS };
		size_t chunk = len > sizeof(pkt.u.msg) ? sizeof(pkt.u.msg) : len;
		memcpy(pkt.u.msg, bytes, chunk);
		pkt.len = chunk;
		if (!client_send_packet(&pkt))
			return false;
		bytes += chunk;
		len -= chunk;
	}
	return true;
}

static bool ctrl_char(const char *token, char *out) {
	if (!token[0] || token[1])
		return false;
	*out = CTRL(token[0]);
	return true;
}

static bool key_token_bytes(const char *token, const char **bytes, size_t *len, char *ctrl) {
	struct KeyName {
		const char *name;
		const char *bytes;
	};
	static const struct KeyName keys[] = {
		{ "Enter", "\r" },
		{ "Return", "\r" },
		{ "C-m", "\r" },
		{ "Tab", "\t" },
		{ "C-i", "\t" },
		{ "Esc", "\033" },
		{ "Escape", "\033" },
		{ "Space", " " },
		{ "Backspace", "\177" },
		{ "BSpace", "\177" },
		{ "Delete", "\033[3~" },
		{ "Insert", "\033[2~" },
		{ "Up", "\033[A" },
		{ "Down", "\033[B" },
		{ "Right", "\033[C" },
		{ "Left", "\033[D" },
		{ "Home", "\033[H" },
		{ "End", "\033[F" },
		{ "PageUp", "\033[5~" },
		{ "PageDown", "\033[6~" },
	};

	for (size_t i = 0; i < countof(keys); i++) {
		if (!strcmp(token, keys[i].name)) {
			*bytes = keys[i].bytes;
			*len = strlen(keys[i].bytes);
			return true;
		}
	}

	if (token[0] == 'C' && token[1] == '-' && ctrl_char(token + 2, ctrl)) {
		*bytes = ctrl;
		*len = 1;
		return true;
	}
	if (token[0] == '^' && ctrl_char(token + 1, ctrl)) {
		*bytes = ctrl;
		*len = 1;
		return true;
	}

	return false;
}

static bool send_keys_session(const char *name, int argc, char *argv[], bool literal) {
	if (server.socket > 0)
		close(server.socket);
	if ((server.socket = session_connect(name)) == -1)
		return false;
	if (!client_expect_pid())
		goto error;

	for (int i = 0; i < argc; i++) {
		const char *bytes = argv[i];
		size_t len = strlen(argv[i]);
		char ctrl;

		if (!literal)
			key_token_bytes(argv[i], &bytes, &len, &ctrl);
		if (!send_bytes(bytes, len))
			goto error;
		if (literal && i + 1 < argc && !send_bytes(" ", 1))
			goto error;
	}

	close(server.socket);
	server.socket = -1;
	return true;

error:
	if (server.socket > 0) {
		close(server.socket);
		server.socket = -1;
	}
	return false;
}

static void client_restore_terminal(void) {
	if (!has_term)
		return;
	tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_term);
	if (alternate_buffer) {
		printf("\033[?25h");
		fflush(stdout);
		alternate_buffer = false;
	}
}

static void client_setup_terminal(void) {
	if (!has_term)
		return;
	atexit(client_restore_terminal);

	cur_term = orig_term;
	cur_term.c_iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL|IXON|IXOFF);
	cur_term.c_oflag &= ~(OPOST);
	cur_term.c_lflag &= ~(ECHO|ECHONL|ICANON|ISIG|IEXTEN);
	cur_term.c_cflag &= ~(CSIZE|PARENB);
	cur_term.c_cflag |= CS8;
	cur_term.c_cc[VLNEXT] = _POSIX_VDISABLE;
	cur_term.c_cc[VMIN] = 1;
	cur_term.c_cc[VTIME] = 0;
	tcsetattr(STDIN_FILENO, TCSANOW, &cur_term);

	if (!alternate_buffer) {
		/* Keep the client in the main screen so terminal scrollback remains usable. */
		printf("\033[H");
		fflush(stdout);
		alternate_buffer = true;
	}
}

static int client_mainloop(void) {
	sigset_t emptyset, blockset;
	sigemptyset(&emptyset);
	sigemptyset(&blockset);
	sigaddset(&blockset, SIGWINCH);
	sigprocmask(SIG_BLOCK, &blockset, NULL);

	client.need_resize = true;
	Packet pkt = {
		.type = MSG_ATTACH,
		.u.i = client.flags,
		.len = sizeof(pkt.u.i),
	};
	client_send_packet(&pkt);

	while (server.running) {
		fd_set fds;
		FD_ZERO(&fds);
		FD_SET(STDIN_FILENO, &fds);
		FD_SET(server.socket, &fds);

		if (client.need_resize) {
			struct winsize ws;
			if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) != -1) {
				Packet pkt = {
					.type = MSG_RESIZE,
					.u = { .ws = { .rows = ws.ws_row, .cols = ws.ws_col } },
					.len = sizeof(pkt.u.ws),
				};
				if (client_send_packet(&pkt))
					client.need_resize = false;
			}
		}

		if (pselect(server.socket+1, &fds, NULL, NULL, NULL, &emptyset) == -1) {
			if (errno == EINTR)
				continue;
			die("client-mainloop");
		}

		if (FD_ISSET(server.socket, &fds)) {
			Packet pkt;
			if (client_recv_packet(&pkt)) {
				switch (pkt.type) {
				case MSG_CONTENT:
					if (!passthrough)
						write_all(STDOUT_FILENO, pkt.u.msg, pkt.len);
					break;
				case MSG_RESIZE:
					client.need_resize = true;
					break;
				case MSG_EXIT:
					client_send_packet(&pkt);
					close(server.socket);
					return pkt.u.i;
				}
			}
		}

		if (FD_ISSET(STDIN_FILENO, &fds)) {
			Packet pkt = { .type = MSG_CONTENT };
			ssize_t len = read(STDIN_FILENO, pkt.u.msg, sizeof(pkt.u.msg));
			if (len == -1 && errno != EAGAIN && errno != EINTR)
				die("client-stdin");
			if (len > 0) {
				debug("client-stdin: %c\n", pkt.u.msg[0]);
				pkt.len = len;
				if (KEY_REDRAW && pkt.u.msg[0] == KEY_REDRAW) {
					client.need_resize = true;
				} else if (pkt.u.msg[0] == KEY_DETACH) {
					pkt.type = MSG_DETACH;
					pkt.len = 0;
					client_send_packet(&pkt);
					close(server.socket);
					return -1;
				} else if (!(client.flags & CLIENT_READONLY)) {
					client_send_packet(&pkt);
				}
			} else if (len == 0) {
				debug("client-stdin: EOF\n");
				return -1;
			}
		}
	}

	return -EIO;
}
