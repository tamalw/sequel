module Sequel
  module JDBC
    module Teradata
      module DatabaseMethods
        
        private
        
        def last_insert_id(conn, opts={})
          if stmt = opts[:stmt]
            rs = stmt.getGeneratedKeys
            begin
              if rs.next
                rs.getInt(1)
              else
                nil
              end
            ensure
              rs.close
            end
          else
            nil
          end
        end

        def requires_return_generated_keys?
          true
        end
      end
    end
  end
end
