require 'active_support/all'
require 'app/logics/circulatie'

module Sinatra
  module MainHelper

    def all_logic_modules
      Fonar::Logic.constants.select{|c| Fonar::Logic.const_get(c).is_a?(Module)}
    end

    def all_logic(m = Fonar::Logic)
      m.public_instance_methods.map{|m| m.to_s}
    end

    def all_logic_url
      #TODO: get parameters class.method(:uitleenbaar).parameters
      @logic_urls ||= begin
                        l = []
                        l += all_logic.map{|m| "#{ConfigFile[:base_path]}/#{m}"}
                        all_logic_modules.each do |c|
                          l += all_logic(Fonar::Logic.const_get(c)).map{|m| "#{ConfigFile[:base_path]}/#{c.downcase}/#{m}"}
                        end
                        l
                        end
    end

    def call_logic
      call_stack = params[:splat].first.split('/')
      call_stack_params = params.select{|k,v| !k.eql?('splat')}
      if call_stack.size > 2
        raise "call stack can only be 1 deep"
      end

      if call_stack.size == 1
        if call_stack_params && call_stack_params.size > 0
          Class.new.extend( Fonar::Logic).send(call_stack[0].to_sym, call_stack_params)
        else
          Class.new.extend( Fonar::Logic).send(call_stack[0].to_sym)
        end
      else
        if call_stack_params && call_stack_params.size > 0
          Class.new.extend( Fonar::Logic.const_get(call_stack[0].classify)).send(call_stack[1].to_sym, call_stack_params)
        else
          Class.new.extend( Fonar::Logic.const_get(call_stack[0].classify)).send(call_stack[1].to_sym)
        end
      end
    rescue ArgumentError => e
      e.message
    rescue StandardError => e
      LOGGER.error(e.class)
      LOGGER.error(e.message)
      raise RuntimeError, "A runtime error occured see logs"
    end

  end
  helpers MainHelper
end