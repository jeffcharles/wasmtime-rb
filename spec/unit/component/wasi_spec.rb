require "spec_helper"
require "json"

module Wasmtime
  module Component
    RSpec.describe "WASI" do
      include_context(:tmpdir)

      before(:all) do
        # Debug engine opts on the engine currently fails assertion: range_start < range_end
        @engine = GLOBAL_ENGINE

        # Compile module only once for speed
        @compiled_wasi_component = @engine.precompile_component(IO.binread("spec/fixtures/wasi-debug-p2.wasm"))
        @compiled_wasi_deterministic_component = @engine.precompile_component(IO.binread("spec/fixtures/wasi-deterministic-p2.wasm"))
      end

      describe "Linker#instantiate" do
        it "prevents panic when Store doesn't have a WASI config" do
          linker = Linker.new(@engine, wasi: true)
          expect { linker.instantiate(Store.new(@engine), wasi_component) }
            .to raise_error(Wasmtime::Error, /Store is missing WASI p2 configuration/)
        end

        it "prevents panic when Store has the wrong WASI config" do
          linker = Linker.new(@engine, wasi: true)
          store = Store.new(@engine, wasi_config: WasiConfig.new.set_stdin_string("some str"))
          expect { linker.instantiate(store, wasi_component) }
            .to raise_error(Wasmtime::Error, /Store is missing WASI p2 configuration/)
        end

        it "returns an instance that can run when store is properly configured" do
          linker = Linker.new(@engine, wasi: true)
          store = Store.new(@engine, wasi_config: WasiConfig.new.use_p2.set_stdin_string("some str"))
          WasiCommand.new(store, wasi_component, linker).call_run(store)
        end
      end

      describe "WasiCommand#new" do
        it "prevents panic when store doesn't have a WASI config" do
          linker = Linker.new(@engine, wasi: true)
          expect { WasiCommand.new(Store.new(@engine), wasi_component, linker) }
            .to raise_error(Wasmtime::Error, /Store is missing WASI p2 configuration/)
        end

        it "prevents panic when store has the wrong WASI config" do
          linker = Linker.new(@engine, wasi: true)
          store = Store.new(@engine, wasi_config: WasiConfig.new.set_stdin_string("some str"))
          expect { WasiCommand.new(store, wasi_component, linker) }
            .to raise_error(Wasmtime::Error, /Store is missing WASI p2 configuration/)
        end

        it "returns an instance that can run when store is properly configured" do
          linker = Linker.new(@engine, wasi: true)
          store = Store.new(@engine, wasi_config: WasiConfig.new.use_p2.set_stdin_string("some str"))
          WasiCommand.new(store, wasi_component, linker).call_run(store)
        end
      end

      # Uses the program from spec/wasi-debug to test the WASI integration
      describe WasiConfig do
        it "writes std streams to files" do
          File.write(tempfile_path("stdin"), "stdin content")
          wasi_config = WasiConfig.new
            .use_p2
            .set_stdin_file(tempfile_path("stdin"))
            .set_stdout_file(tempfile_path("stdout"))
            .set_stderr_file(tempfile_path("stderr"))

          run_wasi_component(wasi_config)

          stdout = JSON.parse(File.read(tempfile_path("stdout")))
          stderr = JSON.parse(File.read(tempfile_path("stderr")))
          expect(stdout.fetch("name")).to eq("stdout")
          expect(stderr.fetch("name")).to eq("stderr")
          expect(stdout.dig("wasi", "stdin")).to eq("stdin content")
        end

        it "writes std streams to buffers" do
          File.write(tempfile_path("stdin"), "stdin content")

          stdout_str = ""
          stderr_str = ""
          wasi_config = WasiConfig.new
            .use_p2
            .set_stdin_file(tempfile_path("stdin"))
            .set_stdout_buffer(stdout_str, 40000)
            .set_stderr_buffer(stderr_str, 40000)

          run_wasi_component(wasi_config)

          parsed_stdout = JSON.parse(stdout_str)
          parsed_stderr = JSON.parse(stderr_str)
          expect(parsed_stdout.fetch("name")).to eq("stdout")
          expect(parsed_stderr.fetch("name")).to eq("stderr")
        end

        it "writes std streams to buffers until capacity" do
          File.write(tempfile_path("stdin"), "stdin content")

          stdout_str = ""
          stderr_str = ""
          wasi_config = WasiConfig.new
            .use_p2
            .set_stdin_file(tempfile_path("stdin"))
            .set_stdout_buffer(stdout_str, 5)
            .set_stderr_buffer(stderr_str, 10)

          run_wasi_component(wasi_config)

          expect(stdout_str).to eq("{\"nam")
          expect(stderr_str).to eq("{\"name\":\"s")
        end

        it "frozen stdout string is not written to" do
          File.write(tempfile_path("stdin"), "stdin content")

          stdout_str = ""
          stderr_str = ""
          wasi_config = WasiConfig.new
            .use_p2
            .set_stdin_file(tempfile_path("stdin"))
            .set_stdout_buffer(stdout_str, 40000)
            .set_stderr_buffer(stderr_str, 40000)

          stdout_str.freeze
          expect { run_wasi_component(wasi_config) }.to raise_error do |error|
            expect(error).to be_a(Wasmtime::Error)
            expect(error.message).to match(/error while executing at wasm backtrace:/)
          end

          parsed_stderr = JSON.parse(stderr_str)
          expect(stdout_str).to eq("")
          expect(parsed_stderr.fetch("name")).to eq("stderr")
        end

        it "frozen stderr string is not written to" do
          File.write(tempfile_path("stdin"), "stdin content")

          stderr_str = ""
          stdout_str = ""
          wasi_config = WasiConfig.new
            .use_p2
            .set_stdin_file(tempfile_path("stdin"))
            .set_stderr_buffer(stderr_str, 40000)
            .set_stdout_buffer(stdout_str, 40000)

          stderr_str.freeze
          expect { run_wasi_component(wasi_config) }.to raise_error do |error|
            expect(error).to be_a(Wasmtime::Error)
            expect(error.message).to match(/error while executing at wasm backtrace:/)
          end

          expect(stderr_str).to eq("")
          expect(stdout_str).to eq("")
        end

        it "reads stdin from string" do
          env = wasi_component_env { |config| config.set_stdin_string("¡UTF-8 from Ruby!") }
          expect(env.fetch("stdin")).to eq("¡UTF-8 from Ruby!")
        end

        it "uses specified args" do
          env = wasi_component_env { |config| config.set_argv(["foo", "bar"]) }
          expect(env.fetch("args")).to eq(["foo", "bar"])
        end

        it "uses ARGV" do
          env = wasi_component_env { |config| config.set_argv(ARGV) }
          expect(env.fetch("args")).to eq(ARGV)
        end

        it "uses specified env" do
          env = wasi_component_env { |config| config.set_env("ENV_VAR" => "VAL") }
          expect(env.fetch("env").to_h).to eq("ENV_VAR" => "VAL")
        end

        it "uses ENV" do
          env = wasi_component_env { |config| config.set_env(ENV) }
          expect(env.fetch("env").to_h).to eq(ENV.to_h)
        end

        describe "#add_determinism" do
          before do
            2.times do |t|
              t += 1
              wasi_config = Wasmtime::WasiConfig
                .new
                .use_p2
                .add_determinism
                .set_stdout_file(tempfile_path("stdout-deterministic-#{t}"))
                .set_stderr_file(tempfile_path("stderr-deterministic-#{t}"))

              deterministic_module = Component.deserialize(@engine, @compiled_wasi_deterministic_component)

              linker = Linker.new(@engine, wasi: true)
              store = Store.new(@engine, wasi_config: wasi_config)
              WasiCommand.new(store, deterministic_module, linker).call_run(store)
            end
          end

          let(:stdout1) {
            # rubocop:disable Performance/ArraySemiInfiniteRangeSlice
            output = File.read(tempfile_path("stdout-deterministic-1"))[1..].strip
            # rubocop:enable Performance/ArraySemiInfiniteRangeSlice
            JSON.parse(output)
          }
          let(:stdout2) {
            # rubocop:disable Performance/ArraySemiInfiniteRangeSlice
            output = File.read(tempfile_path("stdout-deterministic-2"))[1..].strip
            # rubocop:enable Performance/ArraySemiInfiniteRangeSlice
            JSON.parse(output)
          }
          let(:stderr1) { File.read(tempfile_path("stderr-deterministic-1")).strip }
          let(:stderr2) { File.read(tempfile_path("stderr-deterministic-2")).strip }

          it "returns the same random values" do
            expect(stdout1["rand1"]).to eq(stdout2["rand1"])
            expect(stdout1["rand2"]).to eq(stdout2["rand2"])
            expect(stdout1["rand3"]).to eq(stdout2["rand3"])
          end

          it "returns SystemTime returns UTC 0" do
            utc_start_date_str = "1970-01-01T00:00:00+00:00"
            utc_time_keys = %w[utc1 utc2]
            elapsed_time_key = "system_time1_elapsed"
            elapsed_time = "0"

            # Confirm that that time elapsed between utc1 and utc2
            expect(stdout1[elapsed_time_key]).to eq(elapsed_time)
            expect(stdout2[elapsed_time_key]).to eq(elapsed_time)

            utc_time_keys.each do |key|
              expect(stdout1[key]).to eq(utc_start_date_str)
              expect(stdout2[key]).to eq(utc_start_date_str)
            end
          end
        end
      end

      def wasi_component
        Component.deserialize(@engine, @compiled_wasi_component)
      end

      def run_wasi_component(wasi_config)
        linker = Linker.new(@engine, wasi: true)
        store = Store.new(@engine, wasi_config: wasi_config)
        WasiCommand.new(store, wasi_component, linker).call_run(store)
      end

      def wasi_component_env
        stdout_file = tempfile_path("stdout")

        wasi_config = WasiConfig.new.use_p2
        yield(wasi_config)
        wasi_config.set_stdout_file(stdout_file)

        run_wasi_component(wasi_config)

        JSON.parse(File.read(stdout_file)).fetch("wasi")
      end

      def tempfile_path(name)
        File.join(tmpdir, name)
      end
    end
  end
end
