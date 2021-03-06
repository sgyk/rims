# -*- coding: utf-8 -*-

require 'mail'
require 'net/imap'
require 'set'
require 'time'

module RIMS
  module Protocol
    def quote(s)
      qs = ''.encode(s.encoding)
      case (s)
      when /"/, /\n/
        qs << '{' << s.bytesize.to_s << "}\r\n" << s
      else
        qs << '"' << s << '"'
      end
    end
    module_function :quote

    def compile_wildcard(pattern)
      src = '\A'
      src << pattern.gsub(/.*?[*%]/) {|s| Regexp.quote(s[0..-2]) + '.*' }
      src << Regexp.quote($') if $'
      src << '\z'
      Regexp.compile(src)
    end
    module_function :compile_wildcard

    FetchBody = Struct.new(:symbol, :option, :section, :section_list, :partial_origin, :partial_size)

    class FetchBody
      def fetch_att_name
        s = ''
        s << symbol
        s << '.' << option if option
        s << '[' << section << ']'
        if (partial_origin) then
          s << '<' << partial_origin.to_s << '.' << partial_size.to_s << '>'
        end

        s
      end

      def msg_att_name
        s = ''
        s << symbol
        s << '[' << section << ']'
        if (partial_origin) then
          s << '<' << partial_origin.to_s << '>'
        end

        s
      end
    end

    def body(symbol: nil, option: nil, section: nil, section_list: nil, partial_origin: nil, partial_size: nil)
      body = FetchBody.new(symbol, option, section, section_list, partial_origin, partial_size)
    end
    module_function :body

    class RequestReader
      def initialize(input, output, logger)
        @input = input
        @output = output
        @logger = logger
      end

      def read_line
        line = @input.gets or return
        @logger.debug("read line: <#{line.encoding}#{line.ascii_only? ? ':ascii-only' : ''}> #{line.inspect}") if @logger.debug?
        line.chomp!("\n")
        line.chomp!("\r")
        scan_line(line)
      end

      def scan_line(line)
        atom_list = line.scan(/BODY(?:\.\S+)?\[.*?\](?:<\d+\.\d+>)?|[\[\]()]|".*?"|[^\[\]()\s]+/i).map{|s|
          case (s)
          when '(', ')', '[', ']', /\ANIL\z/i
            s.upcase.intern
          when /\A"/
            s.sub(/\A"/, '').sub(/"\z/, '')
          when /\A(?<body_symbol>BODY)(?:\.(?<body_option>\S+))?\[(?<body_section>.*)\](?:<(?<partial_origin>\d+\.(?<partial_size>\d+)>))?\z/i
            body_symbol = $~[:body_symbol]
            body_option = $~[:body_option]
            body_section = $~[:body_section]
            partial_origin = $~[:partial_origin] && $~[:partial_origin].to_i
            partial_size = $~[:partial_size] && $~[:partial_size].to_i
            [ :body,
              Protocol.body(symbol: body_symbol,
                            option: body_option,
                            section: body_section,
                            partial_origin: partial_origin,
                            partial_size: partial_size)
            ]
          else
            s
          end
        }
        if ((atom_list[-1].is_a? String) && (atom_list[-1] =~ /\A{\d+}\z/)) then
          next_size = $&[1..-2].to_i
          @logger.debug("found literal: #{next_size} octets.")
          @output.write("+ continue\r\n")
          @logger.debug('continue literal.') if @logger.debug?
          literal_string = @input.read(next_size) or raise 'unexpected client close.'
          @logger.debug("read literal: <#{literal_string.encoding}#{line.ascii_only? ? ':ascii-only' : ''}> #{literal_string.inspect}") if @logger.debug?
          atom_list[-1] = literal_string
          next_atom_list = read_line or raise 'unexpected client close.'
          atom_list += next_atom_list
        end

        atom_list
      end

      def parse(atom_list, last_atom=nil)
        syntax_list = []
        while (atom = atom_list.shift)
          case (atom)
          when last_atom
            break
          when :'('
            syntax_list.push([ :group ] + parse(atom_list, :')'))
          when :'['
            syntax_list.push([ :block ] + parse(atom_list, :']'))
          else
            if ((atom.is_a? Array) && (atom[0] == :body)) then
              body = atom[1]
              body.section_list = parse(scan_line(body.section))
            end
            syntax_list.push(atom)
          end
        end

        if (atom == nil && last_atom != nil) then
          raise 'syntax error.'
        end

        syntax_list
      end

      def read_command
        while (atom_list = read_line)
          if (atom_list.empty?) then
            next
          end
          if (atom_list.length < 2) then
            raise 'need for tag and command.'
          end
          if (atom_list[0] =~ /\A[*+]/) then
            raise "invalid command tag: #{atom_list[0]}"
          end
          return parse(atom_list)
        end

        nil
      end
    end

    class SearchParser
      def initialize(mail_store, folder)
        @mail_store = mail_store
        @folder = folder
        @charset = nil
        @mail_cache = Hash.new{|hash, uid|
          if (text = @mail_store.msg_text(@folder.mbox_id, uid)) then
            hash[uid] = Mail.new(text)
          end
        }
      end

      def get_mail(msg)
        @mail_cache[msg.uid] or raise "not found a mail: #{msg.uid}"
      end
      private :get_mail

      attr_accessor :charset

      def str2time(time_string)
        if (time_string.is_a? String) then
          begin
            Time.parse(time_string)
          rescue ArgumentError
            nil
          end
        end
      end
      private :str2time

      def string_include?(search_string, text)
        unless (search_string.ascii_only?) then
          if (@charset) then
            search_string = search_string.dup.force_encoding(@charset)
            text = text.encode(@charset)
          end
        end

        text.include? search_string
      end
      private :string_include?

      def mail_body_text(mail)
        case (mail.content_type)
        when /\Atext/i, /\Amessage/i
          text = mail.body.to_s
          if (charset = mail['content-type'].parameters['charset']) then
            if (text.encoding != Encoding.find(charset)) then
              text = text.dup.force_encoding(charset)
            end
          end
          text
        else
          nil
        end
      end
      private :mail_body_text

      def end_of_cond
        proc{|msg| true }
      end
      private :end_of_cond

      def parse_all
        proc{|next_cond|
          proc{|msg|
            next_cond.call(msg)
          }
        }
      end
      private :parse_all

      def parse_msg_flag_enabled(name)
        proc{|next_cond|
          proc{|msg|
            @mail_store.msg_flag(@folder.mbox_id, msg.uid, name) && next_cond.call(msg)
          }
        }
      end
      private :parse_msg_flag_enabled

      def parse_msg_flag_disabled(name)
        proc{|next_cond|
          proc{|msg|
            (! @mail_store.msg_flag(@folder.mbox_id, msg.uid, name)) && next_cond.call(msg)
          }
        }
      end
      private :parse_msg_flag_enabled

      def parse_search_header(name, search_string)
        proc{|next_cond|
          proc{|msg|
            mail = get_mail(msg)
            field_string = (mail[name]) ? mail[name].to_s : ''
            string_include?(search_string, field_string) && next_cond.call(msg)
          }
        }
      end
      private :parse_search_header

      def parse_internal_date(search_time) # :yields: mail_date, boundary
        d = search_time.to_date
        proc{|next_cond|
          proc{|msg|
            yield(@mail_store.msg_date(@folder.mbox_id, msg.uid).to_date, d) && next_cond.call(msg)
          }
        }
      end
      private :parse_internal_date

      def parse_mail_date(search_time) # :yields: internal_date, boundary
        d = search_time.to_date
        proc{|next_cond|
          proc{|msg|
            if (mail_datetime = get_mail(msg).date) then
              yield(mail_datetime.to_date, d) && next_cond.call(msg)
            else
              false
            end
          }
        }
      end
      private :parse_mail_date

      def parse_mail_bytesize(octet_size) # :yields: mail_bytesize, boundary
        proc{|next_cond|
          proc{|msg|
            yield(@mail_store.msg_text(@folder.mbox_id, msg.uid).bytesize, octet_size) && next_cond.call(msg)
          }
        }
      end
      private :parse_mail_bytesize

      def parse_body(search_string)
        proc{|next_cond|
          proc{|msg|
            if (text = mail_body_text(get_mail(msg))) then
              string_include?(search_string, text) && next_cond.call(msg)
            else
              false
            end
          }
        }
      end
      private :parse_body

      def parse_keyword(search_string)
        proc{|next_cond|
          proc{|msg|
            false
          }
        }
      end
      private :parse_keyword

      def parse_new
        proc{|next_cond|
          proc{|msg|
            @mail_store.msg_flag(@folder.mbox_id, msg.uid, 'recent') && \
            (! @mail_store.msg_flag(@folder.mbox_id, msg.uid, 'seen')) && next_cond.call(msg)
          }
        }
      end
      private :parse_new

      def parse_not(next_node)
        operand = next_node.call(end_of_cond)
        proc{|next_cond|
          proc{|msg|
            (! operand.call(msg)) && next_cond.call(msg)
          }
        }
      end
      private :parse_not

      def parse_old
        proc{|next_cond|
          proc{|msg|
            (! @mail_store.msg_flag(@folder.mbox_id, msg.uid, 'recent')) && next_cond.call(msg)
          }
        }
      end
      private :parse_old

      def parse_or(next_node1, next_node2)
        operand1 = next_node1.call(end_of_cond)
        operand2 = next_node2.call(end_of_cond)
        proc{|next_cond|
          proc{|msg|
            (operand1.call(msg) || operand2.call(msg)) && next_cond.call(msg)
          }
        }
      end
      private :parse_or

      def parse_text(search_string)
        search = proc{|text| string_include?(search_string, text) }
        proc{|next_cond|
          proc{|msg|
            mail = get_mail(msg)
            names = mail.header.map{|field| field.name.to_s }
            text = mail_body_text(mail)
            (names.any?{|n| search.call(n) || search.call(mail[n].to_s) } || (! text.nil? && search.call(text))) && next_cond.call(msg)
          }
        }
      end
      private :parse_text

      def parse_uid(msg_set)
        proc{|next_cond|
          proc{|msg|
            (msg_set.include? msg.uid) && next_cond.call(msg)
          }
        }
      end
      private :parse_uid

      def parse_unkeyword(search_string)
        parse_all
      end
      private :parse_unkeyword

      def parse_msg_set(msg_set)
        proc{|next_cond|
          proc{|msg|
            (msg_set.include? msg.num) && next_cond.call(msg)
          }
        }
      end
      private :parse_msg_set

      def parse_group(search_key)
        group_cond = parse_cached(search_key)
        proc{|next_cond|
          proc{|msg|
            group_cond.call(msg) && next_cond.call(msg)
          }
        }
      end
      private :parse_group

      def fetch_next_node(search_key)
        if (search_key.empty?) then
          raise SyntaxError, 'unexpected end of search key.'
        end

        op = search_key.shift
        op = op.upcase if (op.is_a? String)

        case (op)
        when 'ALL'
          factory = parse_all
        when 'ANSWERED'
          factory = parse_msg_flag_enabled('answered')
        when 'BCC'
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of BCC.'
          search_string.is_a? String or raise SyntaxError, "BCC search string expected as <String> but was <#{search_string.class}>."
          factory = parse_search_header('bcc', search_string)
        when 'BEFORE'
          search_date = search_key.shift or raise SyntaxError, 'need for a search date of BEFORE.'
          t = str2time(search_date) or raise SyntaxError, "BEFORE search date is invalid: #{search_date}"
          factory = parse_internal_date(t) {|d, boundary| d < boundary }
        when 'BODY'
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of BODY.'
          search_string.is_a? String or raise SyntaxError, "BODY search string expected as <String> but was <#{search_string.class}>."
          factory = parse_body(search_string)
        when 'CC'
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of CC.'
          search_string.is_a? String or raise SyntaxError, "CC search string expected as <String> but was <#{search_string.class}>."
          factory = parse_search_header('cc', search_string)
        when 'DELETED'
          factory = parse_msg_flag_enabled('deleted')
        when 'DRAFT'
          factory = parse_msg_flag_enabled('draft')
        when 'FLAGGED'
          factory = parse_msg_flag_enabled('flagged')
        when 'FROM'
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of FROM.'
          search_string.is_a? String or raise SyntaxError, "FROM search string expected as <String> but was <#{search_string.class}>."
          factory = parse_search_header('from', search_string)
        when 'HEADER'
          header_name = search_key.shift or raise SyntaxError, 'need for a header name of HEADER.'
          header_name.is_a? String or raise SyntaxError, "HEADER header name expected as <String> but was <#{header_name.class}>."
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of HEADER.'
          search_string.is_a? String or raise SyntaxError, "HEADER search string expected as <String> but was <#{search_string.class}>."
          factory = parse_search_header(header_name, search_string)
        when 'KEYWORD'
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of KEYWORD.'
          search_string.is_a? String or raise SyntaxError, "KEYWORD search string expected as <String> but was <#{search_string.class}>."
          factory = parse_keyword(search_string)
        when 'LARGER'
          octet_size = search_key.shift or raise SyntaxError, 'need for a octet size of LARGER.'
          (octet_size.is_a? String) && (octet_size =~ /\A\d+\z/) or
            raise SyntaxError, "LARGER octet size is expected as numeric string but was <#{octet_size}>."
          factory = parse_mail_bytesize(octet_size.to_i) {|size, boundary| size > boundary }
        when 'NEW'
          factory = parse_new
        when 'NOT'
          next_node = fetch_next_node(search_key)
          factory = parse_not(next_node)
        when 'OLD'
          factory = parse_old
        when 'ON'
          search_date = search_key.shift or raise SyntaxError, 'need for a search date of ON.'
          t = str2time(search_date) or raise SyntaxError, "ON search date is invalid: #{search_date}"
          factory = parse_internal_date(t) {|d, boundary| d == boundary }
        when 'OR'
          next_node1 = fetch_next_node(search_key)
          next_node2 = fetch_next_node(search_key)
          factory = parse_or(next_node1, next_node2)
        when 'RECENT'
          factory = parse_msg_flag_enabled('recent')
        when 'SEEN'
          factory = parse_msg_flag_enabled('seen')
        when 'SENTBEFORE'
          search_date = search_key.shift or raise SyntaxError, 'need for a search date of SENTBEFORE.'
          t = str2time(search_date) or raise SyntaxError, "SENTBEFORE search date is invalid: #{search_date}"
          factory = parse_mail_date(t) {|d, boundary| d < boundary }
        when 'SENTON'
          search_date = search_key.shift or raise SyntaxError, 'need for a search date of SENTON.'
          t = str2time(search_date) or raise SyntaxError, "SENTON search date is invalid: #{search_date}"
          factory = parse_mail_date(t) {|d, boundary| d == boundary }
        when 'SENTSINCE'
          search_date = search_key.shift or raise SyntaxError, 'need for a search date of SENTSINCE.'
          t = str2time(search_date) or raise SyntaxError, "SENTSINCE search date is invalid: #{search_date}"
          factory = parse_mail_date(t) {|d, boundary| d > boundary }
        when 'SINCE'
          search_date = search_key.shift or raise SyntaxError, 'need for a search date of SINCE.'
          t = str2time(search_date) or raise SyntaxError, "SINCE search date is invalid: #{search_date}"
          factory = parse_internal_date(t) {|d, boundary| d > boundary }
        when 'SMALLER'
          octet_size = search_key.shift or raise SyntaxError, 'need for a octet size of SMALLER.'
          (octet_size.is_a? String) && (octet_size =~ /\A\d+\z/) or
            raise SyntaxError, "SMALLER octet size is expected as numeric string but was <#{octet_size}>."
          factory = parse_mail_bytesize(octet_size.to_i) {|size, boundary| size < boundary }
        when 'SUBJECT'
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of SUBJECT.'
          search_string.is_a? String or raise SyntaxError, "SUBJECT search string expected as <String> but was <#{search_string.class}>."
          factory = parse_search_header('subject', search_string)
        when 'TEXT'
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of TEXT.'
          search_string.is_a? String or raise SyntaxError, "TEXT search string expected as <String> but was <#{search_string.class}>."
          factory = parse_text(search_string)
        when 'TO'
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of TO.'
          search_string.is_a? String or raise SyntaxError, "TO search string expected as <String> but was <#{search_string.class}>."
          factory = parse_search_header('to', search_string)
        when 'UID'
          mset_string = search_key.shift or raise SyntaxError, 'need for a message set of UID.'
          mset_string.is_a? String or raise SyntaxError, "UID message set expected as <String> but was <#{search_string.class}>."
          msg_set = @folder.parse_msg_set(mset_string, uid: true)
          factory = parse_uid(msg_set)
        when 'UNANSWERED'
          factory = parse_msg_flag_disabled('answered')
        when 'UNDELETED'
          factory = parse_msg_flag_disabled('deleted')
        when 'UNDRAFT'
          factory = parse_msg_flag_disabled('draft')
        when 'UNFLAGGED'
          factory = parse_msg_flag_disabled('flagged')
        when 'UNKEYWORD'
          search_string = search_key.shift or raise SyntaxError, 'need for a search string of UNKEYWORD.'
          search_string.is_a? String or raise SyntaxError, "UNKEYWORD search string expected as <String> but was <#{search_string.class}>."
          factory = parse_unkeyword(search_string)
        when 'UNSEEN'
          factory = parse_msg_flag_disabled('seen')
        when String
          begin
            msg_set = @folder.parse_msg_set(op, uid: false)
            factory = parse_msg_set(msg_set)
          rescue MessageSetSyntaxError
            raise SyntaxError, "unknown search key: #{op}"
          end
        when Array
          case (op[0])
          when :group
            factory = parse_group(op[1..-1])
          else
            raise SyntaxError, "unknown search key: #{op}"
          end
        else
          raise SyntaxError, "unknown search key: #{op}"
        end

        factory
      end
      private :fetch_next_node

      def parse_cached(search_key)
        unless (search_key.empty?) then
          search_key = search_key.dup
          factory = fetch_next_node(search_key)
          cond = factory.call(parse_cached(search_key))
        else
          cond = end_of_cond
        end
      end
      private :parse_cached

      def parse(search_key)
        cond = parse_cached(search_key)
        proc{|msg|
          found = cond.call(msg)
          @mail_cache.clear
          found
        }
      end
    end

    class FetchParser
      module Utils
        def encode_list(array)
          '('.b << array.map{|v|
            case (v)
            when Symbol
              v.to_s
            when String
              Protocol.quote(v)
            when Integer
              v.to_s
            when NilClass
              'NIL'
            when Array
              encode_list(v)
            else
              raise "unknown value: #{v}"
            end
          }.join(' '.b) << ')'.b
        end
        module_function :encode_list

        def encode_header(header)
          header.map{|field| ''.b << field.name << ': '.b << field.value }.join("\r\n".b) + ("\r\n".b * 2)
        end
        module_function :encode_header

        def get_body_section(mail, index_list)
          if (index_list.empty?) then
            mail
          else
            i, *next_index_list = index_list
            unless (i > 0) then
              raise SyntaxError, "not a none-zero body section number: #{i}"
            end
            if (mail.multipart?) then
              get_body_section(mail.parts[i - 1], next_index_list)
            elsif (mail.content_type == 'message/rfc822') then
              get_body_section(Mail.new(mail.body.raw_source), index_list)
            else
              if (i == 1) then
                if (next_index_list.empty?) then
                  mail
                else
                  nil
                end
              else
                nil
              end
            end
          end
        end
        module_function :get_body_section

        def get_body_content(mail, name, nest_mail: false)
          if (nest_mail) then
            if (mail.content_type == 'message/rfc822') then
              Mail.new(mail.body.raw_source).send(name)
            else
              nil
            end
          else
            mail.send(name)
          end
        end
        module_function :get_body_content
      end
      include Utils

      def initialize(mail_store, folder)
        @mail_store = mail_store
        @folder = folder
        @charset = nil
        @mail_cache = Hash.new{|hash, uid|
          if (text = @mail_store.msg_text(@folder.mbox_id, uid)) then
            hash[uid] = Mail.new(text)
          end
        }
      end

      def get_mail(msg)
        @mail_cache[msg.uid] or raise "not found a mail: #{msg.uid}"
      end
      private :get_mail

      def make_array(value)
        if (value) then
          if (value.is_a? Array) then
            list = value
          else
            list = [ value ]
          end

          if (block_given?) then
            yield(list)
          else
            list
          end
        end
      end
      private :make_array

      def make_address_list(email_address)
        mailbox, host = email_address.split(/@/, 2)
        [ nil, nil, mailbox, host ]
      end
      private :make_address_list

      def expand_macro(cmd_list)
        func_list = cmd_list.map{|name| parse_cached(name) }
        proc{|msg|
          func_list.map{|f| f.call(msg) }.join(' '.b)
        }
      end
      private :expand_macro

      def get_header_field(mail, name, default=nil)
        if (field = mail[name]) then
          if (block_given?) then
            yield(field)
          else
            field
          end
        else
          default
        end
      end
      private :get_header_field

      def get_bodystructure_data(mail)
        if (mail.multipart?) then
          # body_type_mpart
          mpart_data = []
          mpart_data.concat(mail.parts.map{|part| get_bodystructure_data(part) })
          mpart_data << mail['Content-Type'].sub_type
        else
          case (mail.content_type)
          when /\Atext/i        # body_type_text
            text_data = []

            # media_text
            text_data << 'TEXT'
            text_data << mail['Content-Type'].sub_type

            # body_fields
            text_data << mail['Content-Type'].parameters.map{|n, v| [ n, v ] }.flatten
            text_data << mail.content_id
            text_data << mail.content_description
            text_data << mail.content_transfer_encoding
            text_data << mail.raw_source.bytesize

            # body_fld_lines
            text_data << mail.raw_source.each_line.count
          when /\Amessage/i     # body_type_msg
            msg_data = []

            # message_media
            msg_data << 'MESSAGE'
            msg_data << 'RFC822'

            # body_fields
            msg_data << mail['Content-Type'].parameters.map{|n, v| [ n, v ] }.flatten
            msg_data << mail.content_id
            msg_data << mail.content_description
            msg_data << mail.content_transfer_encoding
            msg_data << mail.raw_source.bytesize

            body_mail = Mail.new(mail.body.raw_source)

            # envelope
            msg_data << get_envelope_data(body_mail)

            # body
            msg_data << get_bodystructure_data(body_mail)

            # body_fld_lines
            msg_data << mail.raw_source.each_line.count
          else                  # body_type_basic
            basic_data = []

            # media_basic
            basic_data << get_header_field(mail, 'Content-Type', 'application') {|field| field.main_type }
            basic_data << get_header_field(mail, 'Content-Type', 'octet-stream') {|field| field.sub_type }

            # body_fields
            basic_data << get_header_field(mail, 'Content-Type', []) {|field| field.parameters.map{|n, v| [ n, v ] }.flatten }
            basic_data << mail.content_id
            basic_data << mail.content_description
            basic_data << mail.content_transfer_encoding
            basic_data << mail.raw_source.bytesize
          end
        end
      end
      private :get_bodystructure_data

      def get_envelope_data(mail)
        env_data = []
        env_data << (mail['Date'] && mail['Date'].value)
        env_data << (mail['Subject'] && mail['Subject'].value)
        env_data << make_array(mail.from) {|addr_list| addr_list.map{|addr| make_address_list(addr) } }
        env_data << make_array(mail.sender) {|addr_list| addr_list.map{|addr| make_address_list(addr) } }
        env_data << make_array(mail.reply_to) {|addr_list| addr_list.map{|addr| make_address_list(addr) } }
        env_data << make_array(mail.to) {|addr_list| addr_list.map{|addr| make_address_list(addr) } }
        env_data << make_array(mail.cc) {|addr_list| addr_list.map{|addr| make_address_list(addr) } }
        env_data << make_array(mail.bcc) {|addr_list| addr_list.map{|addr| make_address_list(addr) } }
        env_data << mail.in_reply_to
        env_data << mail.message_id
      end
      private :get_envelope_data

      def parse_body(body, msg_att_name)
        enable_seen = true
        if (body.option) then
          case (body.option.upcase)
          when 'PEEK'
            enable_seen = false
          else
            raise SyntaxError, "unknown fetch body option: #{option}"
          end
        end
        if (@folder.read_only?) then
          enable_seen = false
        end

        if (enable_seen) then
          fetch_flags = parse_flags('FLAGS')
          fetch_flags_changed = proc{|msg|
            unless (@mail_store.msg_flag(@folder.mbox_id, msg.uid, 'seen')) then
              @mail_store.set_msg_flag(@folder.mbox_id, msg.uid, 'seen', true)
              fetch_flags.call(msg) + ' '.b
            else
              ''.b
            end
          }
        else
          fetch_flags_changed = proc{|msg|
            ''.b
          }
        end

        if (body.section_list.empty?) then
          section_text = nil
          section_index_list = []
        else
          if (body.section_list[0] =~ /\A(?<index>\d+(?:\.\d+)*)(?:\.(?<text>.+))?\z/) then
            section_text = $~[:text]
            section_index_list = $~[:index].split(/\./).map{|i| i.to_i }
          else
            section_text = body.section_list[0]
            section_index_list = []
          end
        end

        is_root = section_index_list.empty?
        unless (section_text) then
          if (is_root) then
            fetch_body_content = proc{|mail|
              mail.raw_source
            }
          else
            fetch_body_content = proc{|mail|
              mail.body.raw_source
            }
          end
        else
          section_text = section_text.upcase
          case (section_text)
          when 'MIME'
            if (section_index_list.empty?) then
              raise SyntaxError, "need for section index at #{section_text}."
            else
              fetch_body_content = proc{|mail|
                if (header = get_body_content(mail, :header)) then
                  header.raw_source.strip + ("\r\n".b * 2)
                end
              }
            end
          when 'HEADER'
            fetch_body_content = proc{|mail|
              if (header = get_body_content(mail, :header, nest_mail: ! is_root)) then
                header.raw_source.strip + ("\r\n".b * 2)
              end
            }
          when 'HEADER.FIELDS', 'HEADER.FIELDS.NOT'
            if (body.section_list.length != 2) then
              raise SyntaxError, "need for argument of #{section_text}."
            end
            field_name_list = body.section_list[1]
            unless ((field_name_list.is_a? Array) && (field_name_list[0] == :group)) then
              raise SyntaxError, "invalid argument of #{section_text}: #{field_name_list}"
            end
            field_name_list = field_name_list[1..-1]
            case (section_text)
            when 'HEADER.FIELDS'
              fetch_body_content = proc{|mail|
                if (header = get_body_content(mail, :header, nest_mail: ! is_root)) then
                  encode_header(field_name_list.map{|n| header[n] }.compact)
                end
              }
            when 'HEADER.FIELDS.NOT'
              fetch_body_content = proc{|mail|
                if (header = get_body_content(mail, :header, nest_mail: ! is_root)) then
                  field_name_set = field_name_list.map{|n| header[n] }.compact.map{|i| i.name }.to_set
                  encode_header(header.reject{|i| (field_name_set.include? i.name) })
                end
              }
            else
              raise 'internal error.'
            end
          when 'TEXT'
            fetch_body_content = proc{|mail|
              if (mail_body = get_body_content(mail, :body, nest_mail: ! is_root)) then
                mail_body.raw_source
              end
            }
          else
            raise SyntaxError, "unknown fetch body section text: #{section_text}"
          end
        end

        proc{|msg|
          res = ''.b
          res << fetch_flags_changed.call(msg)
          res << msg_att_name
          res << ' '.b

          mail = get_body_section(get_mail(msg), section_index_list)
          content = fetch_body_content.call(mail) if mail
          if (content) then
            if (body.partial_origin) then
              if (content.bytesize > body.partial_origin) then
                partial_content = content.byteslice((body.partial_origin)..-1)
                if (partial_content.bytesize > body.partial_size) then # because bignum byteslice is failed.
                  partial_content = partial_content.byteslice(0, body.partial_size)
                end
                res << Protocol.quote(partial_content)
              else
                res << 'NIL'.b
              end
            else
              res << Protocol.quote(content)
            end
          else
            res << 'NIL'.b
          end
        }
      end
      private :parse_body

      def parse_bodystructure(name)
        proc{|msg|
          ''.b << name << ' '.b << encode_list(get_bodystructure_data(get_mail(msg)))
        }
      end
      private :parse_bodystructure

      def parse_envelope(name)
        proc{|msg|
          ''.b << name << ' '.b << encode_list(get_envelope_data(get_mail(msg)))
        }
      end
      private :parse_envelope

      def parse_flags(name)
        proc{|msg|
          flag_list = MailStore::MSG_FLAG_NAMES.find_all{|name|
            @mail_store.msg_flag(@folder.mbox_id, msg.uid, name)
          }.map{|name|
            "\\".b << name.capitalize
          }.join(' ')
          ''.b << name << ' (' << flag_list << ')'
        }
      end
      private :parse_flags

      def parse_internaldate(name)
        proc{|msg|
          ''.b << name << @mail_store.msg_date(@folder.mbox_id, msg.uid).strftime(' "%d-%b-%Y %H:%M:%S %z"'.b)
        }
      end
      private :parse_internaldate

      def parse_rfc822_size(name)
        proc{|msg|
          ''.b << name << ' '.b << get_mail(msg).raw_source.bytesize.to_s
        }
      end
      private :parse_rfc822_size

      def parse_uid(name)
        proc{|msg|
          ''.b << name << ' '.b << msg.uid.to_s
        }
      end
      private :parse_uid

      def parse_group(fetch_attrs)
        group_fetch_list = fetch_attrs.map{|fetch_att| parse_cached(fetch_att) }
        proc{|msg|
          '('.b << group_fetch_list.map{|fetch| fetch.call(msg) }.join(' '.b) << ')'.b
        }
      end
      private :parse_group

      def parse_cached(fetch_att)
        fetch_att = fetch_att.upcase if (fetch_att.is_a? String)
        case (fetch_att)
        when 'ALL'
          fetch = expand_macro(%w[ FLAGS INTERNALDATE RFC822.SIZE ENVELOPE ])
        when 'BODY'
          fetch = parse_bodystructure(fetch_att)
        when 'BODYSTRUCTURE'
          fetch = parse_bodystructure(fetch_att)
        when 'ENVELOPE'
          fetch = parse_envelope(fetch_att)
        when 'FAST'
          fetch = expand_macro(%w[ FLAGS INTERNALDATE RFC822.SIZE ])
        when 'FLAGS'
          fetch = parse_flags(fetch_att)
        when 'FULL'
          fetch = expand_macro(%w[ FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODY ])
        when 'INTERNALDATE'
          fetch = parse_internaldate(fetch_att)
        when 'RFC822'
          fetch = parse_body(Protocol.body(section_list: []), fetch_att)
        when 'RFC822.HEADER'
          fetch = parse_body(Protocol.body(option: 'PEEK', section_list: %w[ HEADER ]), fetch_att)
        when 'RFC822.SIZE'
          fetch = parse_rfc822_size(fetch_att)
        when 'RFC822.TEXT'
          fetch = parse_body(Protocol.body(section_list: %w[ TEXT ]), fetch_att)
        when 'UID'
          fetch = parse_uid(fetch_att)
        when Array
          case (fetch_att[0])
          when :group
            fetch = parse_group(fetch_att[1..-1])
          when :body
            body = fetch_att[1]
            fetch = parse_body(body, body.msg_att_name)
          else
            raise SyntaxError, "unknown fetch attribute: #{fetch_att[0]}"
          end
        else
          raise SyntaxError, "unknown fetch attribute: #{fetch_att}"
        end

        fetch
      end
      private :parse_cached

      def parse(fetch_att)
        fetch = parse_cached(fetch_att)
        proc{|msg|
          res = fetch.call(msg)
          @mail_cache.clear
          res
        }
      end
    end

    class Decoder
      def initialize(mail_store_pool, passwd, logger)
        @mail_store_pool = mail_store_pool
        @mail_store_holder = nil
        @folder = nil
        @logger = logger
        @passwd = passwd
      end

      def auth?
        @mail_store_holder != nil
      end

      def selected?
        auth? && (@folder != nil)
      end

      def cleanup
        if (auth?) then
          tmp_mail_store = @mail_store_holder
          @mail_store_holder = nil
          @mail_store_pool.put(tmp_mail_store)
        end

        nil
      end

      def get_mail_store
        @mail_store_holder.mail_store
      end
      private :get_mail_store

      def protect_error(tag)
        begin
          yield
        rescue SyntaxError
          @logger.error('client command syntax error.')
          @logger.error($!)
          [ "#{tag} BAD client command syntax error\r\n" ]
        rescue
          @logger.error('internal server error.')
          @logger.error($!)
          [ "#{tag} BAD internal server error\r\n" ]
        end
      end
      private :protect_error

      def protect_auth(tag, lock: true)
        protect_error(tag) {
          if (auth?) then
            if (lock) then
              @mail_store_holder.user_lock.synchronize{ yield }
            else
              yield
            end
          else
            [ "#{tag} NO not authenticated\r\n" ]
          end
        }
      end
      private :protect_auth

      def protect_select(tag, lock: true)
        protect_auth(tag, lock: lock) {
          if (selected?) then
            yield
          else
            [ "#{tag} NO not selected\r\n" ]
          end
        }
      end
      private :protect_select

      def response_stream(tag)
        Enumerator.new{|res|
          begin
            yield(res)
          rescue SyntaxError
            @logger.error('client command syntax error.')
            @logger.error($!)
            res << "#{tag} BAD client command syntax error\r\n"
          rescue
            @logger.error('internal server error.')
            @logger.error($!)
            res << "#{tag} BAD internal server error\r\n"
          end
        }
      end
      private :response_stream

      def lock_folder
        @mail_store_holder.user_lock.synchronize{
          unless (@folder) then
            raise 'no open folder.'
          end

          unless (get_mail_store.mbox_name(@folder.mbox_id)) then
            raise "deleted folder: #{id}"
          end

          yield
        }
      end
      private :lock_folder

      def ok_greeting
        [ "* OK RIMS v#{VERSION} IMAP4rev1 service ready.\r\n" ]
      end

      def capability(tag)
        [ "* CAPABILITY IMAP4rev1\r\n",
          "#{tag} OK CAPABILITY completed\r\n"
        ]
      end

      def noop(tag)
        protect_error(tag) {
          res = []
          if (auth? && selected?) then
            lock_folder{
              @folder.reload if @folder.updated?
              res << "* #{get_mail_store.mbox_msg_num(@folder.mbox_id)} EXISTS\r\n"
              res << "* #{get_mail_store.mbox_flag_num(@folder.mbox_id, 'recent')} RECENTS\r\n"
            }
          end
          res << "#{tag} OK NOOP completed\r\n"
        }
      end

      def logout(tag)
        protect_error(tag) {
          if (auth? && selected?) then
            lock_folder{
              @folder.reload if @folder.updated?
              @folder.close
              @folder = nil
            }
          end
          cleanup
          res = []
          res << "* BYE server logout\r\n"
          res << "#{tag} OK LOGOUT completed\r\n"
        }
      end

      def authenticate(tag, auth_name)
        [ "#{tag} NO no support mechanism" ]
      end

      def login(tag, username, password)
        protect_error(tag) {
          res = []
          if (@passwd.call(username, password)) then
            cleanup
            @mail_store_holder = @mail_store_pool.get(username)
            if (get_mail_store.abort_transaction?) then
              get_mail_store.recovery_data(logger: @logger).sync
              res << "* OK [ALERT] recovery user data.\r\n"
            end
            res << "#{tag} OK LOGIN completed\r\n"
          else
            res << "#{tag} NO failed to login\r\n"
          end
        }
      end

      def folder_open_msgs
        all_msgs = get_mail_store.mbox_msg_num(@folder.mbox_id)
        recent_msgs = get_mail_store.mbox_flag_num(@folder.mbox_id, 'recent')
        unseen_msgs = all_msgs - get_mail_store.mbox_flag_num(@folder.mbox_id, 'seen')
        yield("* #{all_msgs} EXISTS\r\n")
        yield("* #{recent_msgs} RECENT\r\n")
        yield("* OK [UNSEEN #{unseen_msgs}]\r\n")
        yield("* OK [UIDVALIDITY #{@folder.mbox_id}]\r\n")
        yield("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n")
        nil
      end
      private :folder_open_msgs

      def select(tag, mbox_name)
        protect_auth(tag) {
          res = []
          @folder = nil
          mbox_name_utf8 = Net::IMAP.decode_utf7(mbox_name)
          if (id = get_mail_store.mbox_id(mbox_name_utf8)) then
            @folder = get_mail_store.select_mbox(id)
            folder_open_msgs do |msg|
              res << msg
            end
            res << "#{tag} OK [READ-WRITE] SELECT completed\r\n"
          else
            res << "#{tag} NO not found a mailbox\r\n"
          end
        }
      end

      def examine(tag, mbox_name)
        protect_auth(tag) {
          res = []
          @folder = nil
          mbox_name_utf8 = Net::IMAP.decode_utf7(mbox_name)
          if (id = get_mail_store.mbox_id(mbox_name_utf8)) then
            @folder = get_mail_store.examine_mbox(id)
            folder_open_msgs do |msg|
              res << msg
            end
            res << "#{tag} OK [READ-ONLY] EXAMINE completed\r\n"
          else
            res << "#{tag} NO not found a mailbox\r\n"
          end
        }
      end

      def create(tag, mbox_name)
        protect_auth(tag) {
          res = []
          mbox_name_utf8 = Net::IMAP.decode_utf7(mbox_name)
          if (get_mail_store.mbox_id(mbox_name_utf8)) then
            res << "#{tag} NO duplicated mailbox\r\n"
          else
            get_mail_store.add_mbox(mbox_name_utf8)
            res << "#{tag} OK CREATE completed\r\n"
          end
        }
      end

      def delete(tag, mbox_name)
        protect_auth(tag) {
          res = []
          mbox_name_utf8 = Net::IMAP.decode_utf7(mbox_name)
          if (id = get_mail_store.mbox_id(mbox_name_utf8)) then
            if (id != get_mail_store.mbox_id('INBOX')) then
              get_mail_store.del_mbox(id)
              res << "#{tag} OK DELETE completed\r\n"
            else
              res << "#{tag} NO not delete inbox\r\n"
            end
          else
            res << "#{tag} NO not found a mailbox\r\n"
          end
        }
      end

      def rename(tag, src_name, dst_name)
        protect_auth(tag) {
          src_name_utf8 = Net::IMAP.decode_utf7(src_name)
          dst_name_utf8 = Net::IMAP.decode_utf7(dst_name)
          unless (id = get_mail_store.mbox_id(src_name_utf8)) then
            return [ "#{tag} NO not found a mailbox\r\n" ]
          end
          if (id == get_mail_store.mbox_id('INBOX')) then
            return [ "#{tag} NO not rename inbox\r\n"]
          end
          if (get_mail_store.mbox_id(dst_name_utf8)) then
            return [ "#{tag} NO duplicated mailbox\r\n" ]
          end
          get_mail_store.rename_mbox(id, dst_name_utf8)
          [ "#{tag} OK RENAME completed\r\n" ]
        }
      end

      def subscribe(tag, mbox_name)
        protect_auth(tag) {
          mbox_name_utf8 = Net::IMAP.decode_utf7(mbox_name)
          if (mbox_id = get_mail_store.mbox_id(mbox_name_utf8)) then
            [ "#{tag} OK SUBSCRIBE completed\r\n" ]
          else
            [ "#{tag} NO not found a mailbox\r\n" ]
          end
        }
      end

      def unsubscribe(tag, mbox_name)
        protect_auth(tag) {
          if (mbox_id = get_mail_store.mbox_id(mbox_name)) then
            [ "#{tag} NO not implemented subscribe/unsbscribe command\r\n" ]
          else
            [ "#{tag} NO not found a mailbox\r\n" ]
          end
        }
      end

      def list_mbox(ref_name, mbox_name)
        ref_name_utf8 = Net::IMAP.decode_utf7(ref_name)
        mbox_name_utf8 = Net::IMAP.decode_utf7(mbox_name)

        mbox_filter = Protocol.compile_wildcard(mbox_name_utf8)
        mbox_list = get_mail_store.each_mbox_id.map{|id| [ id, get_mail_store.mbox_name(id) ] }
        mbox_list.keep_if{|id, name| name.start_with? ref_name_utf8 }
        mbox_list.keep_if{|id, name| name[(ref_name_utf8.length)..-1] =~ mbox_filter }

        for id, name_utf8 in mbox_list
          name = Net::IMAP.encode_utf7(name_utf8)
          attrs = '\Noinferiors'
          if (get_mail_store.mbox_flag_num(id, 'recent') > 0) then
            attrs << ' \Marked'
          else
            attrs << ' \Unmarked'
          end
          yield("(#{attrs}) NIL #{Protocol.quote(name)}")
        end

        nil
      end
      private :list_mbox

      def list(tag, ref_name, mbox_name)
        protect_auth(tag) {
          res = []
          if (mbox_name.empty?) then
            res << "* LIST (\\Noselect) NIL \"\"\r\n"
          else
            list_mbox(ref_name, mbox_name) do |mbox_entry|
              res << "* LIST #{mbox_entry}\r\n"
            end
          end
          res << "#{tag} OK LIST completed\r\n"
        }
      end

      def lsub(tag, ref_name, mbox_name)
        protect_auth(tag) {
          res = []
          if (mbox_name.empty?) then
            res << "* LSUB (\\Noselect) NIL \"\"\r\n"
          else
            list_mbox(ref_name, mbox_name) do |mbox_entry|
              res << "* LSUB #{mbox_entry}\r\n"
            end
          end
          res << "#{tag} OK LSUB completed\r\n"
        }
      end

      def status(tag, mbox_name, data_item_group)
        protect_auth(tag) {
          res = []
          mbox_name_utf8 = Net::IMAP.decode_utf7(mbox_name)
          if (id = get_mail_store.mbox_id(mbox_name_utf8)) then
            unless ((data_item_group.is_a? Array) && (data_item_group[0] == :group)) then
              raise SyntaxError, 'second arugment is not a group list.'
            end

            values = []
            for item in data_item_group[1..-1]
              case (item.upcase)
              when 'MESSAGES'
                values << 'MESSAGES' << get_mail_store.mbox_msg_num(id)
              when 'RECENT'
                values << 'RECENT' << get_mail_store.mbox_flag_num(id, 'recent')
              when 'UIDNEXT'
                values << 'UIDNEXT' << get_mail_store.uid(id)
              when 'UIDVALIDITY'
                values << 'UIDVALIDITY' << id
              when 'UNSEEN'
                unseen_flags = get_mail_store.mbox_msg_num(id) - get_mail_store.mbox_flag_num(id, 'seen')
                values << 'UNSEEN' << unseen_flags
              else
                raise SyntaxError, "unknown status data: #{item}"
              end
            end

            res << "* STATUS #{Protocol.quote(mbox_name)} (#{values.join(' ')})\r\n"
            res << "#{tag} OK STATUS completed\r\n"
          else
            res << "#{tag} NO not found a mailbox\r\n"
          end
        }
      end

      def append(tag, mbox_name, *opt_args, msg_text)
        protect_auth(tag) {
          res = []
          mbox_name_utf8 = Net::IMAP.decode_utf7(mbox_name)
          if (mbox_id = get_mail_store.mbox_id(mbox_name_utf8)) then
            msg_flags = []
            msg_date = Time.now

            if ((! opt_args.empty?) && (opt_args[0].is_a? Array)) then
              opt_flags = opt_args.shift
              if (opt_flags[0] != :group) then
                raise SyntaxError, 'bad flag list.'
              end
              for flag_atom in opt_flags[1..-1]
                case (flag_atom.upcase)
                when '\ANSWERED'
                  msg_flags << 'answered'
                when '\FLAGGED'
                  msg_flags << 'flagged'
                when '\DELETED'
                  msg_flags << 'deleted'
                when '\SEEN'
                  msg_flags << 'seen'
                when '\DRAFT'
                  msg_flags << 'draft'
                else
                  raise SyntaxError, "invalid flag: #{flag_atom}"
                end
              end
            end

            if ((! opt_args.empty?) && (opt_args[0].is_a? String)) then
              begin
                msg_date = Time.parse(opt_args.shift)
              rescue ArgumentError
                raise SyntaxError, $!.message
              end
            end

            unless (opt_args.empty?) then
              raise SyntaxError, 'unknown option.'
            end

            uid = get_mail_store.add_msg(mbox_id, msg_text, msg_date)
            for flag_name in msg_flags
              get_mail_store.set_msg_flag(mbox_id, uid, flag_name, true)
            end

            res << "#{tag} OK APPEND completed\r\n"
          else
            res << "#{tag} NO [TRYCREATE] not found a mailbox\r\n"
          end
        }
      end

      def check(tag)
        protect_select(tag) {
          get_mail_store.sync
          [ "#{tag} OK CHECK completed\r\n" ]
        }
      end

      def close(tag)
        protect_select(tag) {
          get_mail_store.sync
          if (@folder) then
            @folder.reload if @folder.updated?
            @folder.close
            @folder = nil
          end
          [ "#{tag} OK CLOSE completed\r\n" ]
        }
      end

      def expunge(tag)
        protect_select(tag) {
          unless (@folder.read_only?) then
            @folder.reload if @folder.updated?

            msg_num_list = []
            @folder.expunge_mbox do |msg_num|
              msg_num_list << msg_num
            end

            response_stream(tag) {|res|
              for msg_num in msg_num_list
                res << "* #{msg_num} EXPUNGE\r\n"
              end
              res << "#{tag} OK EXPUNGE completed\r\n"
            }
          else
            [ "#{tag} NO cannot expunge in read-only mode\r\n" ]
          end
        }
      end

      def search(tag, *cond_args, uid: false)
        protect_select(tag, lock: false) {
          cond = nil

          lock_folder{
            @folder.reload if @folder.updated?
            parser = Protocol::SearchParser.new(get_mail_store, @folder)
            if (cond_args[0].upcase == 'CHARSET') then
              cond_args.shift
              charset_string = cond_args.shift or raise SyntaxError, 'need for a charset string of CHARSET'
              charset_string.is_a? String or raise SyntaxError, "CHARSET charset string expected as <String> but was <#{charset_string.class}>."
              parser.charset = charset_string
            end
            cond = parser.parse(cond_args)
          }

          response_stream(tag) {|res|
            res << '* SEARCH'
            for msg in @folder.msg_list
              begin
                if (lock_folder{ cond.call(msg) }) then
                  if (uid) then
                    res << " #{msg.uid}"
                  else
                    res << " #{msg.num}"
                  end
                end
              rescue SystemCallError
                raise
              rescue
                @logger.warn("failed to search message: uidvalidity(#{@folder.mbox_id}) uid(#{msg.uid})")
                @logger.warn($!)
              end
            end
            res << "\r\n"
            res << "#{tag} OK SEARCH completed\r\n"
          }
        }
      end

      def fetch(tag, msg_set, data_item_group, uid: false)
        protect_select(tag, lock: false) {
          fetch = nil
          msg_list = nil

          lock_folder{
            @folder.reload if @folder.updated?

            msg_set = @folder.parse_msg_set(msg_set, uid: uid)
            msg_list = @folder.msg_list.find_all{|msg|
              if (uid) then
                msg_set.include? msg.uid
              else
                msg_set.include? msg.num
              end
            }

            unless ((data_item_group.is_a? Array) && data_item_group[0] == :group) then
              data_item_group = [ :group, data_item_group ]
            end
            if (uid) then
              unless (data_item_group.find{|i| (i.is_a? String) && (i.upcase == 'UID') }) then
                data_item_group = [ :group, 'UID' ] + data_item_group[1..-1]
              end
            end

            parser = Protocol::FetchParser.new(get_mail_store, @folder)
            fetch = parser.parse(data_item_group)
          }

          response_stream(tag) {|res|
            for msg in msg_list
              begin
                res << ('* '.b << msg.num.to_s.b << ' FETCH '.b << lock_folder{ fetch.call(msg) } << "\r\n".b)
              rescue SystemCallError
                raise
              rescue
                @logger.warn("failed to fetch message: uidvalidity(#{@folder.mbox_id}) uid(#{msg.uid})")
                @logger.warn($!)
              end
            end
            res << "#{tag} OK FETCH completed\r\n"
          }
        }
      end

      def store(tag, msg_set, data_item_name, data_item_value, uid: false)
        protect_select(tag, lock: false) {
          is_silent = nil
          msg_list = nil

          lock_folder{
            return [ "#{tag} NO cannot store in read-only mode\r\n" ] if @folder.read_only?
            @folder.reload if @folder.updated?

            msg_set = @folder.parse_msg_set(msg_set, uid: uid)
            name, option = data_item_name.split(/\./, 2)

            case (name.upcase)
            when 'FLAGS'
              action = :flags_replace
            when '+FLAGS'
              action = :flags_add
            when '-FLAGS'
              action = :flags_del
            else
              raise SyntaxError, "unknown store action: #{name}"
            end

            case (option && option.upcase)
            when 'SILENT'
              is_silent = true
            when nil
              is_silent = false
            else
              raise SyntaxError, "unknown store option: #{option.inspect}"
            end

            if ((data_item_value.is_a? Array) && data_item_value[0] == :group) then
              flag_list = []
              for flag_atom in data_item_value[1..-1]
                case (flag_atom.upcase)
                when '\ANSWERED'
                  flag_list << 'answered'
                when '\FLAGGED'
                  flag_list << 'flagged'
                when '\DELETED'
                  flag_list << 'deleted'
                when '\SEEN'
                  flag_list << 'seen'
                when '\DRAFT'
                  flag_list << 'draft'
                else
                  raise SyntaxError, "invalid flag: #{flag_atom}"
                end
              end
              rest_flag_list = (MailStore::MSG_FLAG_NAMES - %w[ recent ]) - flag_list
            else
              raise SyntaxError, 'third arugment is not a group list.'
            end

            msg_list = @folder.msg_list.find_all{|msg|
              if (uid) then
                msg_set.include? msg.uid
              else
                msg_set.include? msg.num
              end
            }

            for msg in msg_list
              case (action)
              when :flags_replace
                for name in flag_list
                  get_mail_store.set_msg_flag(@folder.mbox_id, msg.uid, name, true)
                end
                for name in rest_flag_list
                  get_mail_store.set_msg_flag(@folder.mbox_id, msg.uid, name, false)
                end
              when :flags_add
                for name in flag_list
                  get_mail_store.set_msg_flag(@folder.mbox_id, msg.uid, name, true)
                end
              when :flags_del
                for name in flag_list
                  get_mail_store.set_msg_flag(@folder.mbox_id, msg.uid, name, false)
                end
              else
                raise "internal error: unknown action: #{action}"
              end
            end
          }

          if (is_silent) then
            [ "#{tag} OK STORE completed\r\n" ]
          else
            response_stream(tag) {|res|
              for msg in msg_list
                flag_atom_list = nil

                lock_folder{
                  if (get_mail_store.msg_exist? @folder.mbox_id, msg.uid) then
                    flag_atom_list = []
                    for name in MailStore::MSG_FLAG_NAMES
                      if (get_mail_store.msg_flag(@folder.mbox_id, msg.uid, name)) then
                        flag_atom_list << "\\#{name.capitalize}"
                      end
                    end
                  end
                }

                if (flag_atom_list) then
                  res << "* #{msg.num} FETCH FLAGS (#{flag_atom_list.join(' ')})\r\n"
                else
                  @logger.warn("not found a message and skipped: uidvalidity(#{@folder.mbox_id}) uid(#{msg.uid})")
                end
              end
              res << "#{tag} OK STORE completed\r\n"
            }
          end
        }
      end

      def copy(tag, msg_set, mbox_name, uid: false)
        protect_select(tag) {
          res = []
          mbox_name_utf8 = Net::IMAP.decode_utf7(mbox_name)
          msg_set = @folder.parse_msg_set(msg_set, uid: uid)

          if (mbox_id = get_mail_store.mbox_id(mbox_name_utf8)) then
            msg_list = @folder.msg_list.find_all{|msg|
              if (uid) then
                msg_set.include? msg.uid
              else
                msg_set.include? msg.num
              end
            }

            for msg in msg_list
              get_mail_store.copy_msg(msg.uid, @folder.mbox_id, mbox_id)
            end

            res << "#{tag} OK COPY completed\r\n"
          else
            res << "#{tag} NO [TRYCREATE] not found a mailbox\r\n"
          end
        }
      end

      def self.repl(decoder, input, output, logger)
        response_write = proc{|res|
          begin
            last_line = nil
            for data in res
              logger.debug("response data: <#{data.encoding}#{data.ascii_only? ? ':ascii-only' : ''}> #{data.inspect}") if logger.debug?
              output << data
              last_line = data
            end
            output.flush
            logger.info("server response: #{last_line.strip}")
          rescue
            logger.error('response write error.')
            logger.error($!)
            raise
          end
        }

        response_write.call(decoder.ok_greeting)

        request_reader = Protocol::RequestReader.new(input, output, logger)
        loop do
          begin
            atom_list = request_reader.read_command
          rescue
            logger.error('invalid client command.')
            logger.error($!)
            response_write.call([ "* BAD client command syntax error\r\n" ])
            next
          end

          break unless atom_list

          tag, command, *opt_args = atom_list
          logger.info("client command: #{tag} #{command}")
          logger.debug("client command parameter: #{opt_args.inspect}") if logger.debug?

          begin
            case (command.upcase)
            when 'CAPABILITY'
              res = decoder.capability(tag, *opt_args)
            when 'NOOP'
              res = decoder.noop(tag, *opt_args)
            when 'LOGOUT'
              res = decoder.logout(tag, *opt_args)
            when 'AUTHENTICATE'
              res = decoder.authenticate(tag, *opt_args)
            when 'LOGIN'
              res = decoder.login(tag, *opt_args)
            when 'SELECT'
              res = decoder.select(tag, *opt_args)
            when 'EXAMINE'
              res = decoder.examine(tag, *opt_args)
            when 'CREATE'
              res = decoder.create(tag, *opt_args)
            when 'DELETE'
              res = decoder.delete(tag, *opt_args)
            when 'RENAME'
              res = decoder.rename(tag, *opt_args)
            when 'SUBSCRIBE'
              res = decoder.subscribe(tag, *opt_args)
            when 'UNSUBSCRIBE'
              res = decoder.unsubscribe(tag, *opt_args)
            when 'LIST'
              res = decoder.list(tag, *opt_args)
            when 'LSUB'
              res = decoder.lsub(tag, *opt_args)
            when 'STATUS'
              res = decoder.status(tag, *opt_args)
            when 'APPEND'
              res = decoder.append(tag, *opt_args)
            when 'CHECK'
              res = decoder.check(tag, *opt_args)
            when 'CLOSE'
              res = decoder.close(tag, *opt_args)
            when 'EXPUNGE'
              res = decoder.expunge(tag, *opt_args)
            when 'SEARCH'
              res = decoder.search(tag, *opt_args)
            when 'FETCH'
              res = decoder.fetch(tag, *opt_args)
            when 'STORE'
              res = decoder.store(tag, *opt_args)
            when 'COPY'
              res = decoder.copy(tag, *opt_args)
            when 'UID'
              unless (opt_args.empty?) then
                uid_command, *uid_args = opt_args
                logger.info("uid command: #{uid_command}")
                logger.debug("uid parameter: #{uid_args}") if logger.debug?
                case (uid_command.upcase)
                when 'SEARCH'
                  res = decoder.search(tag, *uid_args, uid: true)
                when 'FETCH'
                  res = decoder.fetch(tag, *uid_args, uid: true)
                when 'STORE'
                  res = decoder.store(tag, *uid_args, uid: true)
                when 'COPY'
                  res = decoder.copy(tag, *uid_args, uid: true)
                else
                  logger.error("unknown uid command: #{uid_command}")
                  res = [ "#{tag} BAD unknown uid command\r\n" ]
                end
              else
                logger.error('empty uid parameter.')
                res = [ "#{tag} BAD empty uid parameter\r\n" ]
              end
            else
              logger.error("unknown command: #{command}")
              res = [ "#{tag} BAD unknown command\r\n" ]
            end
          rescue ArgumentError
            logger.error('invalid command parameter.')
            logger.error($!)
            res = [ "#{tag} BAD invalid command parameter\r\n" ]
          rescue
            logger.error('internal server error.')
            logger.error($!)
            res = [ "#{tag} BAD internal server error\r\n" ]
          end

          response_write.call(res)

          if (command.upcase == 'LOGOUT') then
            break
          end
        end

        nil
      end
    end
  end
end

# Local Variables:
# mode: Ruby
# indent-tabs-mode: nil
# End:
